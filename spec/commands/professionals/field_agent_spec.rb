require "rails_helper"

RSpec.describe "Módulo 10 — ACS e agente de endemias sem conselho (F-24.2)" do
  before { clinical_city! }

  let(:admin) { staff_with("admin-campo@cidade.gov.br", "municipal_admin") }
  let(:unit) { create_unit("UBS Campo") }
  let(:user) { staff_with("acs-#{SecureRandom.hex(2)}@cidade.gov.br", "health_professional") }

  it "cria o perfil sem conselho e abre vínculo 515105 e 515140; CNS continua obrigatório" do
    result = Professionals::Create.call(user_id: user.id, attrs: { professional_name: "Rosana Moreira", cns: valid_cns(1) }, by: admin)
    expect(result).to be_ok
    professional = result.payload[:professional]
    expect(professional).to have_attributes(council: nil, council_state: nil, registration_number: nil)
    expect(Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: "515105", by: admin)).to be_ok
    expect(Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: "515140", by: admin)).to be_ok
    expect(Professionals::Create.call(user_id: staff_with("x-#{SecureRandom.hex(2)}@c.gov.br", "health_professional").id,
                                      attrs: { professional_name: "Sem CNS" }, by: admin).details[:fields]).to include("cns")
  end

  it "conselho, UF e registro em branco valem como ausentes (não viram string vazia)" do
    result = Professionals::Create.call(user_id: user.id, by: admin,
                                        attrs: { professional_name: "Rosana Moreira", cns: valid_cns(5), council: "", council_state: " ", registration_number: "" })
    expect(result).to be_ok
    expect(result.payload[:professional].reload).to have_attributes(council: nil, council_state: nil, registration_number: nil)
  end

  it "perfil sem conselho não abre CBO que exige conselho; conselho pela metade é inválido" do
    professional = Professionals::Create.call(user_id: user.id, attrs: { professional_name: "Rosana Moreira", cns: valid_cns(2) }, by: admin).payload[:professional]
    expect(Professionals::OpenLink.call(professional: professional, health_unit_id: unit.id, cbo_code: "223505", by: admin).reason).to eq(:council_mismatch)
    other = staff_with("y-#{SecureRandom.hex(2)}@c.gov.br", "health_professional")
    expect(Professionals::Create.call(user_id: other.id, attrs: { professional_name: "Meio", cns: valid_cns(3), council: "COREN" }, by: admin).details[:fields])
      .to include("council")
  end

  it "conselho pela metade tem mensagem em português" do
    professional = Professional.new(user: user, professional_name: "Meio", cns: valid_cns(6), council: "COREN")
    expect(professional).not_to be_valid
    expect(professional.errors.full_messages_for(:council).join).not_to include("translation missing")
    expect(professional.errors.messages_for(:council)).to include(a_string_matching(/conselho.*UF.*registro/i))
  end

  it "tirar o conselho de quem tem vínculo que o exige → council_in_use" do
    nurse = care_nurse!(unit)
    result = Professionals::UpdateProfile.call(professional: nurse.professional, attrs: { council: nil, council_state: nil, registration_number: nil }, by: admin)
    expect(result.reason).to eq(:council_in_use)
  end

  it "tirar o conselho de quem só tem vínculo de campo é permitido" do
    acs = registry_acs!(unit)
    professional = acs.professional
    professional.update_columns(council: "COREN", council_state: "PR", registration_number: "123")
    result = Professionals::UpdateProfile.call(professional: professional, attrs: { council: nil, council_state: nil, registration_number: nil }, by: admin)
    expect(result).to be_ok
    expect(professional.reload.council).to be_nil
  end

  it "documento e impressão não quebram com conselho nulo" do
    professional = Professionals::Create.call(user_id: user.id, attrs: { professional_name: "Rosana Moreira", cns: valid_cns(4) }, by: admin).payload[:professional]
    expect(ClinicalDocuments::Json.council(professional)).to be_nil
    expect(ClinicalDocuments::Json.council(nil)).to be_nil
  end
end
