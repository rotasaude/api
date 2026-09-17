require "rails_helper"

# Spec §7: automação autentica por bearer, sem cookie e sem CORS. Cookie e
# bearer juntos são recusados: não pode haver dúvida sobre quem agiu.
RSpec.describe "Maintenance token authentication", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:password) { "s3nha-forte-1" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "ta-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end
  let(:issued) do
    MaintenanceToken.issue!(maintainer: maintainer, name: "ci", access: "read_write",
                            city_slugs: [], expires_at: 10.days.from_now)
  end
  let(:token) { issued.first }
  let(:secret) { issued.last }

  def json = JSON.parse(response.body)
  def bearer(value = secret) = { "Authorization" => "Bearer #{value}" }
  def browser = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def query!(headers) = post("/graphql", params: { query: "{ me { id } }" }, headers: headers)

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with(MaintenanceApi::ORIGIN).and_return(frontend)
  end

  it "authenticates a token without Origin, header or cookie" do
    query!(bearer)

    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "me", "id")).to eq(maintainer.id)
    expect(token.reload.last_used_at).to be_present
  end

  it "refuses a cookie and a bearer in the same request" do
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: browser
    post "/session/challenge", params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: browser

    query!(browser.merge(bearer))

    expect(response).to have_http_status(:unauthorized)
    expect(json).to include("error" => "ambiguous_credentials")
  end

  it "refuses an expired, revoked, unknown or foreign-environment token, and audits the refusal" do
    query!(bearer("#{MaintenanceToken.prefix}nao-existe"))
    expect(response).to have_http_status(:unauthorized)

    token.revoke!
    query!(bearer)
    expect(response).to have_http_status(:unauthorized)

    expect(PlatformEvent.where(name: "maintenance.token.refused").count).to eq(2)
    expect(PlatformEvent.where(name: "maintenance.token.refused").last.payload).to include("outcome" => "rejected")
  end

  it "refuses a token whose owner was deactivated" do
    maintainer.deactivate!

    query!(bearer)

    expect(response).to have_http_status(:unauthorized)
  end

  it "keeps the browser path unchanged: no bearer means Origin and header are still required" do
    query!({ "Origin" => "https://attacker.example", "X-Rota-Maintenance" => "1" })

    expect(response).to have_http_status(:forbidden)
  end

  # Fix round 1 (Critical): um segredo recusado sem o formato conhecido não
  # pode virar dado gravado na auditoria — nem inteiro, nem em pedaço.
  it "never echoes an unrecognized secret into the audit trail" do
    garbage = "nounderscoreshere"
    query!(bearer(garbage))

    expect(response).to have_http_status(:unauthorized)

    event = PlatformEvent.where(name: "maintenance.token.refused").last
    expect(event.payload["token_prefix"]).to eq("unrecognized")
    expect(event.payload.to_json).not_to include(garbage)
    expect(event.payload.to_json).not_to include(garbage.first(8))
  end

  # Fix round 1 (I3): /session é do navegador. Um bearer não vira sessão ali —
  # nem para ler, nem para encerrar.
  it "refuses a bearer-authenticated GET /session" do
    get "/session", headers: bearer

    expect(response).to have_http_status(:forbidden)
    expect(json).to eq({ "error" => "browser_only" })
  end

  it "refuses a bearer-authenticated DELETE /session" do
    delete "/session", headers: bearer

    expect(response).to have_http_status(:forbidden)
    expect(json).to eq({ "error" => "browser_only" })
  end
end
