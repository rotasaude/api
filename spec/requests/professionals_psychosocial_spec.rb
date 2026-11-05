require "rails_helper"

# Módulo 31 (ADR 0049; P29): a equipe do CAPS (psychosocial_staff e
# psychosocial_lead) é elegível a perfil profissional SEM o papel
# health_professional (que abriria a UBS ao CAPS pela leitura contextual).
# Os papéis não elegíveis continuam recusados.
RSpec.describe "Perfil profissional da equipe do CAPS", type: :request do
  def json = JSON.parse(response.body)

  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:attrs) do
    { professional_name: "Camila Farias", council: "CRP", council_state: "PR", registration_number: "12345", cns: Professionals::Cns.generate("camila") }
  end

  %w[psychosocial_staff psychosocial_lead].each do |role|
    it "usuário só com #{role} ganha perfil pelo comando e não ganha health_professional" do
      user = staff_with("#{role}@cidade.gov.br", role)
      result = Current.set(city: TEST_CITY_A) { Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin) }

      aggregate_failures do
        expect(result).to be_ok
        expect(user.reload.professional).to have_attributes(professional_name: "Camila Farias", council: "CRP")
        expect(user.has_role?("health_professional")).to be(false)
      end
    end
  end

  it "POST /professionals cria o perfil de quem só tem psychosocial_staff" do
    user = staff_with("psi@cidade.gov.br", "psychosocial_staff")
    sign_in_as(admin)
    json_post "/professionals", attrs.merge(user_id: user.id)

    expect(response).to have_http_status(:created)
    expect(json["professional"]).to include("user_id" => user.id)
  end

  it "GET /professionals/pending lista a equipe do CAPS sem perfil e, com perfil, sem vínculo" do
    novo = staff_with("novo@cidade.gov.br", "psychosocial_lead")
    com_perfil = staff_with("psi@cidade.gov.br", "psychosocial_staff")
    Current.set(city: TEST_CITY_A) { Professionals::Create.call(user_id: com_perfil.id, attrs: attrs, by: admin) }
    sign_in_as(admin)
    get "/professionals/pending"

    expect(json["users"]).to contain_exactly(
      { "user_id" => novo.id, "email_address" => novo.email_address, "status" => "missing_profile" },
      { "user_id" => com_perfil.id, "email_address" => com_perfil.email_address, "status" => "missing_link" }
    )
  end

  it "papel não elegível continua recusado com user_missing_role" do
    %w[viewer lab_staff billing_clerk].each_with_index do |role, index|
      user = staff_with("#{role}@cidade.gov.br", role)
      result = Current.set(city: TEST_CITY_A) do
        Professionals::Create.call(user_id: user.id, attrs: attrs.merge(registration_number: (900 + index).to_s), by: admin)
      end

      expect(result.reason).to eq(:user_missing_role)
    end
    expect(Professional.count).to eq(0)
  end

  it "papel do CAPS revogado: user_missing_role" do
    user = staff_with("psi@cidade.gov.br", "psychosocial_staff")
    user.memberships.sole.revoke!

    expect(Current.set(city: TEST_CITY_A) { Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin) }.reason).to eq(:user_missing_role)
  end
end
