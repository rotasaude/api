require "rails_helper"

# Spec da API de manutenção §8: endpoint único, POST-only, uma operação por
# requisição, com limite de profundidade, complexidade e tamanho. Nesta fatia o
# schema tem só `me` — o resto chega nas fatias de leitura e mutation.
RSpec.describe "Maintenance GraphQL", type: :request do
  let(:password) { "s3nha-forte-1" }
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "gql-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def headers = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: headers
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: headers
    expect(response).to have_http_status(:ok)
  end

  def query!(query, **variables)
    post "/graphql", params: { query: query, variables: variables }, headers: headers
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAINTENANCE_FRONTEND_ORIGIN").and_return(frontend)
  end

  it "refuses an unauthenticated query" do
    query!("{ me { emailAddress } }")

    expect(response).to have_http_status(:unauthorized)
  end

  it "answers me for a verified session" do
    login!
    query!("{ me { id emailAddress } }")

    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "me")).to include("id" => maintainer.id, "emailAddress" => maintainer.email_address)
  end

  it "refuses GET, because a query in the URL lands in logs and caches" do
    login!
    get "/graphql", params: { query: "{ me { id } }" }, headers: headers

    expect(response).to have_http_status(:not_found)
  end

  it "refuses a query above the size limit" do
    login!
    query!("{ me { id } } #{'#' * (Maintenance::GraphqlController::MAX_QUERY_BYTES + 1)}")

    expect(response).to have_http_status(:payload_too_large)
  end

  it "refuses a request above the body size limit, even with a small query" do
    login!
    query!("{ me { id } }", padding: "x" * Maintenance::GraphqlController::MAX_BODY_BYTES)

    expect(response).to have_http_status(:payload_too_large)
    expect(response.body).to be_blank
  end

  it "refuses a query above the complexity limit" do
    login!
    aliases = 220.times.map { |i| "a#{i}: id" }.join(" ")
    query!("{ me { #{aliases} } }")

    expect(response).to have_http_status(:ok)
    expect(json["errors"]).to be_present
    expect(json["errors"].first["message"]).to match(/complexity/i)
    expect(json["data"]).to be_nil
  end

  # A profundidade real alcançável hoje é 2 (Query.me -> campo escalar): todo
  # campo de MaintainerType é folha (ID/String/DateTime), e GraphQL proíbe
  # selecionar sub-campo de escalar — não existe query válida que chegue a
  # depth 11 com o schema de hoje. A prova comportamental chega no Plano 4,
  # com o primeiro tipo aninhado (cidades). Por ora, prova-se a configuração.
  it "configures the depth limit, proven behaviorally once a nested type exists (Plan 4)" do
    expect(Maintenance::Schema.max_depth).to eq(10)
  end

  it "answers an error, not a crash, for an unknown field" do
    login!
    query!("{ cidades { slug } }")

    expect(response).to have_http_status(:ok)
    expect(json["errors"].first["message"]).to include("cidades")
    expect(json["data"]).to be_nil
  end

  it "keeps introspection out of the deployed environments" do
    login!
    allow(Rota).to receive(:deployed?).and_return(true)
    query!("{ __schema { types { name } } }")

    expect(json["errors"]).to be_present
  end
end
