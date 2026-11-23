require "rails_helper"

# Módulo 35b (ADR 0054; Q30): a equipe de zoonoses (zoonoses_team) é elegível
# a perfil profissional e a vínculo sem o papel health_professional — a
# veterinária (223305, CRMV) ganha o perfil pelo caminho de sempre, como a
# equipe do CAPS (P29). O perfil é opcional para o papel: a pendência não
# lista quem só tem zoonoses_team e não tem perfil.
RSpec.describe "Perfil profissional da equipe de zoonoses", type: :request do
  def json = JSON.parse(response.body)

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:attrs) do
    { professional_name: "Vera Lúcia Prado", council: "CRMV", council_state: "PR", registration_number: "4321",
      cns: Professionals::Cns.generate("vera") }
  end

  def create_profile(user, **over)
    Current.set(city: TEST_CITY_A) { Professionals::Create.call(user_id: user.id, attrs: attrs.merge(over), by: admin) }
  end

  it "usuário só com zoonoses_team ganha perfil e vínculo 223305 na UVZ e vira veterinarian?, sem health_professional" do
    user = staff_with("vet@cidade.gov.br", "zoonoses_team")
    uvz = create_unit("UVZ Teste", kind: "environmental_surveillance")
    result = create_profile(user)
    link = Current.set(city: TEST_CITY_A) do
      Professionals::OpenLink.call(professional: user.reload.professional, health_unit_id: uvz.id, cbo_code: "223305", by: admin)
    end

    aggregate_failures do
      expect(result).to be_ok
      expect(link).to be_ok
      expect(user.reload.professional).to have_attributes(council: "CRMV", registration_number: "4321")
      expect(user.has_role?("health_professional")).to be(false)
      expect(Zoonoses::Access.veterinarian?(user)).to be(true)
      expect(Professionals::ClinicalAuthorization.check(user: user, health_unit_id: uvz.id)).to eq(:missing_role)
    end
  end

  it "GET /professionals/pending não lista quem só tem zoonoses_team sem perfil; com perfil e sem vínculo, sim" do
    sem_perfil = staff_with("zoo@cidade.gov.br", "zoonoses_team")
    com_perfil = staff_with("vet@cidade.gov.br", "zoonoses_team")
    create_profile(com_perfil)
    clinico = staff_with("medica@cidade.gov.br", "zoonoses_team", "health_professional")
    sign_in_as(admin)
    get "/professionals/pending"

    expect(json["users"]).to contain_exactly(
      { "user_id" => com_perfil.id, "email_address" => com_perfil.email_address, "status" => "missing_link" },
      { "user_id" => clinico.id, "email_address" => clinico.email_address, "status" => "missing_profile" }
    )
    expect(json["users"].map { |row| row["user_id"] }).not_to include(sem_perfil.id)
  end

  it "os papéis do perfil e do vínculo incluem zoonoses_team" do
    expect(Professional::PROFILE_ROLES).to include("zoonoses_team")
    expect(Professional::LINK_ROLES).to include("zoonoses_team")
  end
end
