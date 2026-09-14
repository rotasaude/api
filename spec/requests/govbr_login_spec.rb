require "rails_helper"

# Login gov.br com callback único em auth.* (spec §5, Plano 3B):
#   cidade  POST /auth/govbr/start      → authorize_url (state assinado: cidade + nonce)
#   auth.*  GET  /auth/govbr/callback   → provisiona NA cidade do state, emite grant de usuário, 302 para a cidade
#   cidade  POST /session/grant         → sessão do usuário (Task 3)
RSpec.describe "gov.br login through the single auth callback", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:city_a) { City.find_by!(slug: TEST_CITY_A.slug) }
  let(:claims_base) { { "sub" => "12345678900", "email" => "fulano@gov.br", "amr" => [ "prata" ], "email_verified" => true } }

  def json = JSON.parse(response.body)
  def query_of(url) = Rack::Utils.parse_query(URI.parse(url).query)

  before do
    allow(Authenticator::GovBr).to receive_messages(
      client_id: "rota-client", redirect_uri: "https://auth.rotasaude.app/auth/govbr/callback",
      issuer_url: "https://sso.staging.acesso.gov.br"
    )
  end

  # Começa no host da cidade e devolve [state, nonce].
  def start_on(host)
    post "/auth/govbr/start", headers: { "HOST" => host }
    expect(response).to have_http_status(:ok)
    query = query_of(json.fetch("authorize_url"))
    [ query.fetch("state"), query.fetch("nonce") ]
  end

  def callback(state:, code: "valid-code")
    get "/auth/govbr/callback", params: { code: code, state: state }, headers: { "HOST" => "auth.rotasaude.app" }
  end

  def stub_exchange(nonce)
    allow(Authenticator::GovBr).to receive(:exchange_code_for_claims).with("valid-code").and_return(claims_base.merge("nonce" => nonce))
  end

  it "redirects back to the city with a grant that opens the user's session" do
    state, nonce = start_on(test_city_host)
    stub_exchange(nonce)

    callback(state: state)

    expect(response).to have_http_status(:found)
    expect(response.location).to start_with("http://#{TEST_CITY_A.slug}.localhost:5175/dashboard/?grant=")
    user = User.find_by!(email_address: "fulano@gov.br")
    expect(DomainEvent.where(name: "identity.govbr_login").last.payload).to include("user_id" => user.id)

    post "/session/grant", params: { token: query_of(response.location).fetch("grant") }, headers: { "HOST" => test_city_host }
    expect(response).to have_http_status(:created)
    expect(json).to include("id" => user.id, "operator" => false)
    expect(json).not_to have_key("mfa_required")
  end

  it "provisions the user only in the city named by the state" do
    city_b = create(:city, slug: TEST_CITY_B.slug, status: "active", database_url: city_database_url("rota_saude_test_city_b"))
    state, nonce = start_on("#{TEST_CITY_B.slug}.rotasaude.app")
    stub_exchange(nonce)

    callback(state: state)

    expect(response).to have_http_status(:found)
    expect(response.location).to start_with("http://#{TEST_CITY_B.slug}.localhost:5175/dashboard/?grant=")
    expect(CityConnection.with(city_b) { User.where(email_address: "fulano@gov.br").count }).to eq(1)
    expect(User.where(email_address: "fulano@gov.br").count).to eq(0) # cidade A (conexão padrão)
    expect(CityGrant.order(:created_at).last).to have_attributes(city_id: city_b.id, kind: "user")
  end

  it "refuses a nonce that is not the one in the state, creating nothing" do
    state, _nonce = start_on(test_city_host)
    stub_exchange("outro-nonce")

    expect { callback(state: state) }.not_to change(CityGrant, :count)

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_nonce")
    expect(User.where(email_address: "fulano@gov.br")).to be_empty
  end

  it "refuses a tampered or expired state without calling gov.br" do
    state, _nonce = start_on(test_city_host)
    expect(Authenticator::GovBr).not_to receive(:exchange_code_for_claims)

    callback(state: "#{state}x")
    expect(response).to have_http_status(:bad_request)
    expect(json).to eq("error" => "invalid_state")

    travel 11.minutes do
      callback(state: state)
    end
    expect(response).to have_http_status(:bad_request)
  end

  it "answers 404 when the state names a city that is not servable" do
    state, _nonce = start_on(test_city_host)
    city_a.update!(status: "suspended")
    CityCatalog.reset_cache!

    callback(state: state)

    expect(response).to have_http_status(:not_found)
    expect(json).to eq("error" => "unknown_city")
  end

  it "refuses to link an existing city user when the callback email is not verified, issuing nothing" do
    User.create!(email_address: "fulano@gov.br", password: "secret123")
    state, nonce = start_on(test_city_host)
    allow(Authenticator::GovBr).to receive(:exchange_code_for_claims)
      .with("valid-code").and_return(claims_base.merge("nonce" => nonce, "email_verified" => false))

    expect { callback(state: state) }.not_to change(CityGrant, :count)

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "govbr_unauthenticated")
  end

  it "refuses a deactivated user without issuing a grant" do
    User.create!(email_address: "fulano@gov.br", password: "secret123", deactivated_at: Time.current)
    state, nonce = start_on(test_city_host)
    stub_exchange(nonce)

    expect { callback(state: state) }.not_to change(CityGrant, :count)

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "govbr_unauthenticated")
  end

  it "answers 502 on an integration failure, issuing nothing" do
    state, _nonce = start_on(test_city_host)
    allow(Authenticator::GovBr).to receive(:exchange_code_for_claims).and_raise(Authenticator::GovBr::IntegrationError, "boom")

    expect { callback(state: state) }.not_to change(CityGrant, :count)

    expect(response).to have_http_status(:bad_gateway)
    expect(json).to eq("error" => "govbr_integration_error")
  end

  it "is not served on a city host nor on the console host" do
    state, _nonce = start_on(test_city_host)

    [ test_city_host, "admin.rotasaude.app" ].each do |host|
      get "/auth/govbr/callback", params: { code: "valid-code", state: state }, headers: { "HOST" => host }
      expect(response).to have_http_status(:not_found), "#{host} respondeu #{response.status}"
    end
  end

  it "start answers 502 when gov.br is not configured" do
    allow(Authenticator::GovBr).to receive(:client_id).and_raise(Authenticator::GovBr::IntegrationError, "missing GOVBR_CLIENT_ID")

    post "/auth/govbr/start"

    expect(response).to have_http_status(:bad_gateway)
    expect(json).to eq("error" => "govbr_integration_error")
  end
end
