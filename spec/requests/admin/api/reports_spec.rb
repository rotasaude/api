require "rails_helper"

RSpec.describe "Admin::Api::Reports", type: :request do
  # No `municipality_id:` anywhere below (db/city_schema.rb never had the
  # column on any of these tables) — the city is the connection, not a
  # foreign key. `seed_report` runs on whatever connection is current, so a
  # caller wanting a second city's data wraps it in `CityConnection.with`.
  def seed_report(tier: "alta", token: "tok-#{SecureRandom.hex(4)}")
    pd = ProtocolDefinition.create!(name: "resp", version: 3, status: "active",
                                    definition: { "name" => "resp", "version" => 3, "start_step_id" => "s1",
                                                  "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean" }] })
    convo = Conversation.create!(phone: "+5511#{rand(1000..9999)}", state: "completed")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "resp",
                            status: "completed", tier: tier, answers: {})
    ReportSnapshot.create!(triage: triage, protocol_definition: pd,
                           token: token, signature: "sig-#{token}",
                           payload: { "secret_clinical" => "NEVER-EXPOSE" }, outcome: { "tier" => tier, "priority" => 2 },
                           expires_at: 10.days.from_now)
  end

  def municipal_admin_for(email:)
    user = User.create!(email_address: email, password: "secret123")
    Membership.create!(user: user, role: "municipal_admin", granted_at: Time.current)
    user
  end

  it "an operator sees a city's reports as metadata, without token or payload" do
    skip "Plano 3: grant de operador — não há mais papel de plataforma em Membership " \
         "(ck_memberships_role só aceita os 4 papéis locais) nem painel cross-tenant em " \
         "Admin::Api (D6: /admin/api/cities e as queries cross-tenant foram removidas); " \
         "o painel de relatórios agora é POR CIDADE, como Triages — sem gate de operador " \
         "para reconstruir aqui. A cobertura de metadados/LGPD (sem token/payload na " \
         "resposta) sobrevive no exemplo abaixo, do lado do municipal_admin."
  end

  it "a municipal_admin sees only their own city's reports (per-city, not operator-only)" do
    seed_report(tier: "alta", token: "TOK-SECRET-123")
    other_city = create(:city, slug: TEST_CITY_B.slug, status: "active",
                               database_url: city_database_url("rota_saude_test_city_b"))
    CityConnection.with(other_city) { seed_report(tier: "baixa") }
    admin = municipal_admin_for(email: "adm-#{SecureRandom.hex(3)}@x.com")
    sign_in_as(admin)

    get "/admin/api/reports", params: { period: "30d" }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    reports = body.dig("data", "reports")
    expect(reports.size).to eq(1) # só a cidade dele
    row = reports.first
    expect(row["tier"]).to eq("alta")
    expect(row["protocol"]).to eq("resp · 3")
    expect(row["createdAt"]).to be_present
    expect(row).to have_key("live")
    expect(body["as_of"]).to be_present
    # LGPD: no token / payload / signature anywhere in the response
    expect(response.body).not_to include("TOK-SECRET-123")
    expect(response.body).not_to include("NEVER-EXPOSE")
  end

  it "requires authentication (401 when unauthenticated)" do
    get "/admin/api/reports", params: { period: "30d" }
    expect(response).to have_http_status(:unauthorized)
  end

  it "a city user with no active membership must not see the city's reports" do
    pending "Plano 3: gate de membership — hoje Admin::Api::BaseController só exige " \
            "sessão autenticada (require_authentication), sem checar Membership nenhum " \
            "(revisão 5b M3); um usuário da cidade sem qualquer membership ainda lê o " \
            "painel da própria cidade. Este exemplo assere o comportamento DESEJADO (403) " \
            "para virar falha visível quando o Plano 3 acrescentar o gate de membership."
    seed_report(tier: "alta")
    homeless = User.create!(email_address: "no-membership-#{SecureRandom.hex(3)}@x.com", password: "secret123")
    sign_in_as(homeless)

    get "/admin/api/reports", params: { period: "30d" }

    expect(response).to have_http_status(:forbidden)
  end
end
