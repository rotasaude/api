require "rails_helper"

RSpec.describe Professional do
  let(:user) { staff_with("medica@cidade.gov.br", "health_professional") }

  def build_professional(**overrides)
    described_class.new({ user: user, professional_name: "  Helena   Duarte ", council: "CRM", council_state: "pr",
                          registration_number: "12.345", cns: "7000 0000 0000 005" }.merge(overrides))
  end

  it "normaliza nome, UF, registro e CNS" do
    p = build_professional
    expect(p).to be_valid
    expect(p).to have_attributes(professional_name: "Helena Duarte", council_state: "PR",
                                 registration_number: "12345", cns: "700000000000005")
  end

  it "normaliza telefone e e-mail de contato; vazio vira nil" do
    p = build_professional(phone: "(41) 99876-5432", contact_email: " Helena@Clinica.org ")
    expect(p).to have_attributes(phone: "41998765432", contact_email: "helena@clinica.org")
    expect(build_professional(phone: "", contact_email: "")).to have_attributes(phone: nil, contact_email: nil)
  end

  {
    professional_name: "   ", council: "XYZ", council_state: "ZZ", registration_number: "12345678901",
    cns: "712345678901237", phone: "4199", contact_email: "sem-arroba"
  }.each do |field, value|
    it "recusa #{field} = #{value.inspect}" do
      p = build_professional(field => value)
      expect(p).not_to be_valid
      expect(p.errors.attribute_names).to include(field)
    end
  end

  it "cns_masked mostra só os 4 últimos" do
    expect(build_professional.cns_masked).to eq("*** **** **** 0005")
  end
end
