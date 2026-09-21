require "rails_helper"

# Spec do frontend §6: a tela de mantenedores lista e-mail, estado e
# matrícula. Só sessão humana — o analisador HumanOnly já lista `maintainers`.
RSpec.describe "Maintenance maintainers query", type: :request do
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "zz-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let!(:pending) { Maintainer.create!(email_address: "aa-#{SecureRandom.hex(3)}@rotasaude.app") }
  let!(:gone) do
    Maintainer.create!(email_address: "mm-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current, deactivated_at: Time.current)
  end

  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)
  def query = "{ maintainers { id emailAddress active enrolled createdAt } }"

  def login!
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser
    expect(response).to have_http_status(:ok)
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
  end

  it "lists every maintainer by e-mail, with state and enrollment" do
    login!

    post "/graphql", params: { query: query }, headers: browser

    listed = json.dig("data", "maintainers")
    emails = [ pending, gone, maintainer ].map(&:email_address)
    expect(listed.map { |m| m["emailAddress"] } & emails).to eq(emails.sort)
    by_email = listed.index_by { |m| m["emailAddress"] }
    expect(by_email[pending.email_address]).to include("active" => true, "enrolled" => false)
    expect(by_email[gone.email_address]).to include("active" => false, "enrolled" => true)
    expect(by_email[maintainer.email_address]).to include("active" => true, "enrolled" => true)
  end

  it "is refused to a service token" do
    _token, secret = MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read",
                                             city_slugs: [], expires_at: 5.days.from_now)

    post "/graphql", params: { query: query }, headers: { "Authorization" => "Bearer #{secret}", "Cookie" => "" }

    expect(json["errors"].first["extensions"]["code"]).to eq("TOKEN_SCOPE_REFUSED")
    expect(json["data"]).to be_nil
  end

  it "never exposes a credential of a maintainer" do
    login!

    post "/graphql", params: { query: query }, headers: browser

    %w[password_digest otp_secret token_digest].each { |forbidden| expect(response.body).not_to include(forbidden) }
    expect(response.body).not_to include(maintainer.otp_secret)
  end
end
