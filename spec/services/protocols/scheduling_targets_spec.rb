require "rails_helper"

# Contratos §1/§9: tipo inexistente (ou desativado) na cidade só avisa.
RSpec.describe Protocols::SchedulingTargets do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def definition(*keys)
    { "scheduling" => keys.map { |k| { "when" => { "gte" => ["outcome.score", 1] }, "appointment_type" => k,
                                        "priority" => "routine", "due_in_days" => 7 } } }
  end

  it "avisa tipo inexistente e desativado; tipo ativo não avisa" do
    AppointmentType.create!(key: "consulta_medica", name: "Consulta médica", duration_minutes: 20,
                            cbo_prefixes: ["2251"], origin: "platform")
    AppointmentType.create!(key: "acupuntura", name: "Acupuntura", duration_minutes: 30, cbo_prefixes: ["2251"],
                            origin: "city", active: false)
    expect(described_class.warnings(definition("consulta_medica", "fantasma", "acupuntura"))).to eq([
      "scheduling appointment_type 'fantasma' does not exist in this city",
      "scheduling appointment_type 'acupuntura' is inactive in this city"
    ])
  end

  it "total: sem scheduling ou com lixo, nenhum aviso" do
    expect(described_class.warnings({})).to eq([])
    expect(described_class.warnings({ "scheduling" => "x" })).to eq([])
    expect(described_class.warnings(nil)).to eq([])
  end
end
