require "rails_helper"

# Fechamento do módulo 07 (ADR-0020): a mesma invariante de
# spec/cities/city_isolation_spec.rb, agora pela porta de entrada real — o Host.
# Os quatro isolamentos do critério de fechamento e onde cada um é provado:
#   dado    — spec/cities/city_isolation_spec.rb (conexão) e este arquivo (Host);
#             role de cidade sem CONNECT no banco vizinho: spec/services/city_database_spec.rb
#   sessão  — spec/requests/city_session_isolation_spec.rb, spec/requests/operator_city_session_spec.rb
#   job     — spec/models/city_connection_queue_spec.rb, spec/jobs/concerns/city_scoped_job_spec.rb
#   grant   — spec/requests/session_grant_spec.rb, spec/services/city_grants_spec.rb
RSpec.describe "City isolation through the Host", type: :request do
  let!(:city_b) do
    create(:city, slug: TEST_CITY_B.slug, status: "active", database_url: city_database_url("rota_saude_test_city_b"))
  end

  def city_b_host = "#{TEST_CITY_B.slug}.rotasaude.app"

  def viewer_session
    user = User.create!(email_address: "iso-#{SecureRandom.hex(4)}@x.com", password: "secret123")
    Membership.create!(user: user, role: "viewer", granted_at: 2.days.ago)
    sign_in_as(user)
  end

  it "o host de A lê só o banco de A, mesmo com evento de mesmo nome gravado em B" do
    DomainEvent.create!(name: "triage.completed", occurred_at: 1.hour.ago, payload: { "triage_id" => "de-a" })
    CityConnection.with(city_b) do
      DomainEvent.create!(name: "triage.completed", occurred_at: 1.hour.ago, payload: { "triage_id" => "de-b" })
    end
    viewer_session

    get "/admin/api/events", params: { period: "7d" }

    expect(response).to have_http_status(:ok)
    refs = JSON.parse(response.body).dig("data", "stream").map { |e| e["ref"] }
    expect(refs).to eq(["triage_id=de-a"])
  end

  it "o cookie de A não abre o banco de B: 401, sem dado de B na resposta" do
    CityConnection.with(city_b) do
      DomainEvent.create!(name: "triage.completed", occurred_at: 1.hour.ago, payload: { "triage_id" => "so-b" })
    end
    viewer_session

    get "/admin/api/events", params: { period: "7d" }, headers: { "HOST" => city_b_host }

    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("so-b")
  end

  # A cidade é resolvida ANTES da autenticação: host desconhecido responde 404
  # mesmo com um cookie de sessão válido em outra cidade.
  it "host desconhecido responde 404 antes de autenticar, mesmo com cookie válido" do
    viewer_session

    get "/admin/api/events", params: { period: "7d" }, headers: { "HOST" => "inexistente.rotasaude.app" }

    expect(response).to have_http_status(:not_found)
    expect(JSON.parse(response.body)["error"]).to eq("unknown_city")
  end
end
