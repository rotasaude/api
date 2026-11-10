require "rails_helper"

# Módulo 32b (contrato Q2/Q3): quem checa a medicação e quem lê o mapa de
# observação.
RSpec.describe Urgency::Access do
  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:other_unit) { create_unit("UPA Outra", kind: "upa") }
  after { Current.reset }

  it "o técnico 322205 vinculado à UPA checa a medicação, mas não tem o vínculo clínico" do
    tech = screener!(upa, cbo: "322205")
    expect(described_class.nursing_or_physician_link(tech, upa.id)).to be_a(ProfessionalLink)
    expect(described_class.clinical_link(tech, upa.id)).to be_nil
    expect(described_class.observation_reader?(tech, upa.id)).to be(true)
  end

  it "enfermeiro e médico da UPA têm o vínculo de checagem" do
    expect(described_class.nursing_or_physician_link(upa_nurse!(upa), upa.id)).to be_present
    expect(described_class.nursing_or_physician_link(upa_doctor!(upa), upa.id)).to be_present
  end

  it "a recepção lê o mapa sem vínculo" do
    reception = upa_reception!
    expect(described_class.nursing_or_physician_link(reception, upa.id)).to be_nil
    expect(described_class.observation_reader?(reception, upa.id)).to be(true)
  end

  it "um enfermeiro de outra unidade não lê o mapa desta" do
    nurse = upa_nurse!(other_unit)
    expect(described_class.nursing_or_physician_link(nurse, upa.id)).to be_nil
    expect(described_class.observation_reader?(nurse, upa.id)).to be(false)
  end

  it "usuário nulo não lê" do
    expect(described_class.observation_reader?(nil, upa.id)).to be(false)
  end
end
