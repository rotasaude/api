require "rails_helper"

RSpec.describe Ledi::ProductionSummary do
  around { |ex| CityConnection.with(register_test_city!) { ex.run } }

  def entry!(status, competence: "202610", codes: nil, replaces: nil)
    attrs = { uuid: "1234567-#{SecureRandom.uuid}", ficha_type: "procedimento", competence: competence,
              source_type: "synthetic", source_id: SecureRandom.uuid, ledi_version: "8.7.0",
              next_attempt_at: Time.current, status: status, last_error_codes: codes || [] }
    attrs[:replaces_outbox_id] = replaces.id if replaces
    attrs[:accepted_at] = Time.current if status == "accepted"
    attrs[:bytes] = "x".b unless status == "accepted"
    LediOutboxEntry.create!(attrs)
  end

  before do
    3.times { entry!("accepted") }
    entry!("rejected", codes: [ { "field" => "cnes", "code" => "not_allowed" } ])
    entry!("rejected", codes: [ { "field" => "cnes", "code" => "not_allowed" } ])
    entry!("rejected", codes: [ { "field" => "cboCodigo_2002", "code" => "not_allowed" } ])
    entry!("pending")
    entry!("failed", codes: Ledi::ErrorCodes.transport("http_error"))
    entry!("accepted", competence: "202609")
  end

  it "conta por status só da competência pedida" do
    expect(described_class.counts("202610")).to eq(accepted: 3, rejected: 3, pending: 1, sending: 0, failed: 1)
  end

  it "agrupa recusas por campo e código" do
    expect(described_class.rejections("202610")).to eq([
      { field: "cnes", code: "not_allowed", count: 2 }, { field: "cboCodigo_2002", code: "not_allowed", count: 1 }
    ])
  end

  it "monta o resumo com prazo, dias úteis e alerta" do
    summary = described_class.call(competence: "202610", today: Date.new(2026, 11, 10), record_mode: "record")
    expect(summary.slice(:competence, :deadline_on, :business_days_left, :alert))
      .to eq(competence: "202610", deadline_on: Date.new(2026, 11, 16), business_days_left: 5, alert: "attention")
  end

  # Spec §5: a recusada regerada deixa de contar — a linha nova é quem conta.
  it "recusada já regerada não conta nas contagens, nas recusas nem no alerta" do
    LediOutboxEntry.where(competence: "202610").where.not(status: "accepted").delete_all
    rejected = entry!("rejected", codes: [ { "field" => "cnes", "code" => "not_allowed" } ])
    summary = -> { described_class.call(competence: "202610", today: Date.new(2026, 11, 10), record_mode: "record") }
    expect(summary.call).to include(alert: "attention", rejections: [ { field: "cnes", code: "not_allowed", count: 1 } ])

    entry!("accepted", replaces: rejected)
    expect(described_class.counts("202610")).to eq(accepted: 4, rejected: 0, pending: 0, sending: 0, failed: 0)
    expect(summary.call).to include(alert: "none", rejections: [])
    expect(rejected.reload.status).to eq("rejected")
  end
end
