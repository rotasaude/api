require "rails_helper"

# Spec da API de manutenção §6: senha abre sessão PENDENTE, TOTP verifica, e o
# cookie só autentica depois disso. Poderes totais ⇒ sessão curta, bloqueio por
# conta e CSRF por Origin + header próprio.
RSpec.describe "Maintainer session", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:password) { "s3nha-forte-1" }
  let(:frontend) { "https://maintenance.rotasaude.app" }
  let!(:maintainer) do
    Maintainer.create!(email_address: "m-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                       otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
  end

  def api_host = "maintenance-api.rotasaude.app"
  def json = JSON.parse(response.body)
  def totp = ROTP::TOTP.new(maintainer.otp_secret).now
  def headers = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }

  def login!(pwd = password)
    post "/session", params: { email_address: maintainer.email_address, password: pwd }, headers: headers
  end

  def verified_login!
    login!
    post "/session/challenge", params: { session_id: json["session_id"], code: totp }, headers: headers
    expect(response).to have_http_status(:ok)
  end

  before do
    host! api_host
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAINTENANCE_FRONTEND_ORIGIN").and_return(frontend)
  end

  it "opens a pending session on the password step, which does not authenticate yet" do
    login!

    expect(response).to have_http_status(:ok)
    expect(json).to include("mfa_required" => true)
    expect(MaintainerSession.find(json["session_id"]).mfa_verified_at).to be_nil

    get "/session", headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "authenticates after TOTP and audits the login with the maintainer id, never the e-mail" do
    verified_login!

    get "/session", headers: headers
    expect(response).to have_http_status(:ok)
    expect(json).to include("email_address" => maintainer.email_address)

    event = PlatformEvent.where(name: "maintenance.session.started").last
    expect(event.payload).to include("maintainer_id" => maintainer.id, "outcome" => "ok")
    expect(event.payload.to_json).not_to include(maintainer.email_address)
  end

  it "writes a host-only, HttpOnly, SameSite=Strict cookie" do
    login!
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")

    expect(set_cookie).to include("maintainer_session_id")
    expect(set_cookie).to match(/HttpOnly/i)
    expect(set_cookie).to match(/SameSite=Strict/i)
    expect(set_cookie).not_to include("domain")
  end

  it "expires the session eight hours after the TOTP, and after thirty idle minutes" do
    verified_login!
    login_time = Time.current

    # Absolute TTL: touching the session every twenty-five minutes (well
    # within IDLE_TTL) keeps it alive right up to eight hours, so the 401 just
    # past eight hours is provably the ABSOLUTE limit, not idleness — a single
    # check seven hours after login, with no activity in between, would have
    # already tripped the thirty-minute idle limit and proven nothing about
    # the absolute one.
    (1..19).each do |step|
      travel_to(login_time + (step * 25.minutes)) do
        get "/session", headers: headers
        expect(response).to have_http_status(:ok)
      end
    end

    travel_to(login_time + 8.hours + 1.minute) do
      get "/session", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end

    # Idle TTL: a single gap over thirty minutes kills the session well inside
    # the eight-hour absolute window, with no activity in between.
    verified_login!
    travel_to(31.minutes.from_now) do
      get "/session", headers: headers
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "locks the account after five bad passwords, then refuses the right one" do
    Maintainer::LOCKOUT_ATTEMPTS.times { login!("errada") }

    expect(maintainer.reload.locked?).to be(true)
    expect(PlatformEvent.where(name: "maintenance.session.locked").count).to eq(1)

    login!
    expect(response).to have_http_status(:unauthorized)
    expect(json).to include("error" => "locked")
  end

  it "pays the same bcrypt cost for an unknown e-mail as for a known one, to not enumerate accounts" do
    expect(BCrypt::Password).to receive(:new).with(Maintenance::SessionsController::DUMMY_DIGEST).and_call_original

    post "/session", params: { email_address: "nao-existe-#{SecureRandom.hex(3)}@rotasaude.app", password: "qualquer" },
                      headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(json).to include("error" => "invalid_credentials")
  end

  it "refuses a request without the exact Origin or without the header" do
    verified_login!

    get "/session", headers: { "Origin" => "https://attacker.example", "X-Rota-Maintenance" => "1" }
    expect(response).to have_http_status(:forbidden)

    get "/session", headers: { "Origin" => frontend }
    expect(response).to have_http_status(:forbidden)
  end

  it "answers 404 on any other host, never 401" do
    host! "curitiba.rotasaude.app"
    get "/session", headers: headers
    expect(response).to have_http_status(:not_found)

    host! "admin.rotasaude.app"
    post "/session", params: { email_address: maintainer.email_address, password: password }, headers: headers
    expect(response).not_to have_http_status(:ok)
  end

  it "refuses a deactivated maintainer and ends the session on logout" do
    verified_login!
    delete "/session", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(PlatformEvent.where(name: "maintenance.session.ended").count).to eq(1)

    maintainer.deactivate!
    login!
    expect(response).to have_http_status(:unauthorized)
  end
end
