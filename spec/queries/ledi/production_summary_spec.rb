require "rails_helper"

RSpec.describe Ledi::ProductionSummary do
  around { |ex| CityConnection.with(register_test_city!) { ex.run } }

  def entry!(status, competence: "202610", error: nil)
    attrs = { uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: competence,
              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
              next_attempt_at: Time.current, status: status, last_error: error }
    attrs[:accepted_at] = Time.current if status == "accepted"
    attrs[:bytes] = "x".b unless status == "accepted"
    LediOutboxEntry.create!(attrs)
  end

  before do
    3.times { entry!("accepted") }
    entry!("rejected", error: "CNES 1234567 não pertence ao município")
    entry!("rejected", error: "CNES 1234567 não pertence ao município")
    entry!("rejected", error: "CBO incompatível")
    entry!("pending")
    entry!("failed", error: "HTTP 500")
    entry!("accepted", competence: "202609")
  end

  it "conta por status só da competência pedida" do
    expect(described_class.counts("202610")).to eq(accepted: 3, rejected: 3, pending: 1, sending: 0, failed: 1)
  end

  it "agrupa recusas por mensagem, da mais frequente para a menos" do
    expect(described_class.rejections("202610")).to eq([
      { message: "CNES 1234567 não pertence ao município", count: 2 }, { message: "CBO incompatível", count: 1 }
    ])
  end

  it "monta o resumo com prazo, dias úteis e alerta" do
    summary = described_class.call(competence: "202610", today: Date.new(2026, 11, 10), record_mode: "record")
    expect(summary.slice(:competence, :deadline_on, :business_days_left, :alert))
      .to eq(competence: "202610", deadline_on: Date.new(2026, 11, 16), business_days_left: 5, alert: "attention")
  end
end
