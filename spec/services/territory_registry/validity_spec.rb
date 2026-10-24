require "rails_helper"

# F-24.6 (contrato §6; §14 L5, L19): validade de 24 meses contada do dia da
# última gravação; sem CPF e sem CNS = missing_identifier, decidido depois da
# saída e da recusa e antes da validade.
RSpec.describe TerritoryRegistry::Validity do
  let(:today) { Date.new(2026, 10, 23) }

  def reg(at, refused: false, exit: nil) = instance_double(IndividualRegistration, registered_at: at.in_time_zone, refused?: refused, exit_reason: exit)
  def status(registration, identified: true) = described_class.status(registration, today: today, identified: identified)

  it "24 meses contados do dia; vence logo = até 60 dias antes" do
    expect(status(reg(Date.new(2024, 10, 23)))).to eq("expired")
    expect(status(reg(Date.new(2024, 10, 24)))).to eq("due_soon")
    expect(status(reg(Date.new(2024, 12, 22)))).to eq("due_soon")
    expect(status(reg(Date.new(2024, 12, 23)))).to eq("valid")
    expect(status(reg(Date.new(2026, 1, 1), refused: true))).to eq("refused")
    expect(status(reg(Date.new(2026, 1, 1), exit: "moved"))).to eq("exited")
  end

  it "sem CPF e sem CNS: missing_identifier depois de saída e recusa, antes de vencido/a vencer/válido" do
    expect(status(reg(Date.new(2024, 1, 1)), identified: false)).to eq("missing_identifier")
    expect(status(reg(Date.new(2024, 11, 1)), identified: false)).to eq("missing_identifier")
    expect(status(reg(Date.new(2026, 1, 1)), identified: false)).to eq("missing_identifier")
    expect(status(reg(Date.new(2026, 1, 1), refused: true), identified: false)).to eq("refused")
    expect(status(reg(Date.new(2026, 1, 1), exit: "death"), identified: false)).to eq("exited")
  end

  it "conta o dia da cidade, não o UTC" do
    late = Time.find_zone!("America/Sao_Paulo").local(2024, 10, 23, 23, 30)
    registration = instance_double(IndividualRegistration, registered_at: late.utc, refused?: false, exit_reason: nil)
    Time.use_zone("America/Sao_Paulo") { expect(status(registration)).to eq("expired") }
  end
end
