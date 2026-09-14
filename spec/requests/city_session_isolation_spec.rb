require "rails_helper"

# Spec §5: resolver a cidade ANTES de autenticar é o que torna o cookie de uma
# cidade inútil na vizinha — sem nenhuma verificação de aplicação, só a conexão.
RSpec.describe "City session isolation", type: :request do
  let(:password) { "secret123" }
  let!(:user_a) { User.create!(email_address: "pessoa@cidade.gov.br", password: password) }
  # Mesmo slug de TEST_CITY_B: a requisição ao host de B e o CityConnection.with
  # deste spec compartilham a sessão pinada daquele shard (ver o harness).
  let!(:city_b) do
    create(:city, slug: TEST_CITY_B.slug, status: "active", database_url: city_database_url("rota_saude_test_city_b"))
  end

  def city_b_host = "#{TEST_CITY_B.slug}.rotasaude.app"
  def set_cookie_header = Array(response.headers["Set-Cookie"]).join("\n")

  def login_on_city_a
    post "/session", params: { email_address: user_a.email_address, password: password }
    expect(response).to have_http_status(:created)
    set_cookie_header[/session_id=[^;]+/]
  end

  it "the session cookie is host-only (no Domain attribute)" do
    login_on_city_a

    expect(set_cookie_header).to match(/session_id=/)
    expect(set_cookie_header).not_to match(/domain=/i)
  end

  it "a session created in city A authenticates in A and not in B" do
    cookie = login_on_city_a

    get "/session", headers: { "Cookie" => cookie }
    expect(response).to have_http_status(:ok) # controle positivo: mesma cidade

    get "/session", headers: { "HOST" => city_b_host, "Cookie" => cookie }
    expect(response).to have_http_status(:unauthorized)
  end

  it "the same email existing in city B does not make A's cookie valid there" do
    CityConnection.with(city_b) { User.create!(email_address: user_a.email_address, password: password) }
    cookie = login_on_city_a

    get "/session", headers: { "HOST" => city_b_host, "Cookie" => cookie }

    expect(response).to have_http_status(:unauthorized)
  end

  it "city A's credentials do not log in on city B" do
    post "/session", params: { email_address: user_a.email_address, password: password },
                     headers: { "HOST" => city_b_host }

    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body)).to eq("error" => "invalid_credentials")
  end

  it "logging in on the city answers 201 with operator: false, never mfa_required, even with MFA enrolled" do
    Mfa::Enroll.call(user_a)
    user_a.update!(otp_enabled: true)

    post "/session", params: { email_address: user_a.email_address, password: password }

    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body).to include("operator" => false, "email_address" => user_a.email_address, "mfa_enrolled" => true)
    expect(body).not_to have_key("mfa_required")
  end

  it "the city no longer offers the operator TOTP challenge" do
    post "/session/challenge", params: { session_id: SecureRandom.uuid, code: "123456" }

    expect(response).to have_http_status(:not_found)
  end
end
