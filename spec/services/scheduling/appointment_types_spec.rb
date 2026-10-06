require "rails_helper"

# ADR 0029 §3.1: a base é copiada (só o que falta), a cidade ajusta e o
# catálogo resolve nome, tipos ativos e o tipo padrão por CBO.
RSpec.describe Scheduling::AppointmentTypes do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  it "copia a base uma vez e nunca sobrescreve o ajuste da cidade" do
    expect(described_class.seed_platform!).to eq(4)
    AppointmentType.find_by!(key: "consulta_medica").update!(duration_minutes: 30, active: false)
    expect(described_class.seed_platform!).to eq(0)
    expect(AppointmentType.find_by!(key: "consulta_medica")).to have_attributes(duration_minutes: 30, active: false)
    expect(AppointmentType.listed.pluck(:key, :origin, :position)).to eq([
      [ "consulta_medica", "platform", 1 ], [ "consulta_enfermagem", "platform", 2 ],
      [ "consulta_odontologica", "platform", 3 ], [ "retorno", "platform", 4 ]
    ])
  end

  it "serves? casa pelo prefixo do CBO" do
    described_class.seed_platform!
    medica = AppointmentType.find_by!(key: "consulta_medica")
    expect(described_class.serves?(medica, "225125")).to be(true)
    expect(described_class.serves?(medica, "223505")).to be(false)
    expect(described_class.serves?(AppointmentType.find_by!(key: "retorno"), "223208")).to be(true)
  end

  it "catálogo: nome (ou a key), ativos e o padrão da base na ordem do arquivo" do
    described_class.seed_platform!
    type_row!("acupuntura", cbo: ["2251"], active: false)
    catalog = described_class.catalog
    expect(catalog.name_for("consulta_enfermagem")).to eq("Consulta de enfermagem")
    expect(catalog.name_for("fantasma")).to eq("fantasma")
    expect(catalog.name_for(nil)).to be_nil
    expect(catalog.active.keys).to contain_exactly("consulta_medica", "consulta_enfermagem", "consulta_odontologica", "retorno")
    expect(catalog.fallback.map(&:key)).to eq(%w[consulta_medica consulta_enfermagem consulta_odontologica retorno])
    expect(catalog.fallback.find { |t| t.serves?("223505") }.key).to eq("consulta_enfermagem")
  end
end
