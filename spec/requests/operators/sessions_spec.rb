require "rails_helper"

# Login do operador no console de plataforma (admin.*), contra Operator no banco
# de plataforma. Operador exige TOTP a cada login (ADR-0011): a senha só abre uma
# sessão PENDENTE; o cookie só autentica depois do challenge.
RSpec.describe "Operator session on the platform console", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:password) { "s3nha-forte-1" }
  let!(:operator) { create_operator("op") }

  def create_operator(prefix)
    Operator.create!(email_address: "#{prefix}-#{SecureRandom.hex(3)}@rotasaude.app", password: password,
                     otp_secret: ROTP::Base32.random, otp_enabled: true)
  end

  def console_host = "admin.rotasaude.app"
  def json = JSON.parse(response.body)
  def set_cookie_header = Array(response.headers["Set-Cookie"]).join("\n")
  def totp(op = operator) = ROTP::TOTP.new(op.otp_secret).now

  def login!(op = operator, pwd = password)
    post "/session", params: { email_address: op.email_address, password: pwd }
  end

  def verified_login!
    login!
    post "/session/challenge", params: { session_id: json["session_id"], code: totp }
    expect(response).to have_http_status(:ok)
  end

  # O before global de request specs aponta para o host da cidade de teste; este
  # before roda depois e troca para o console.
  before { host! console_host }

  it "answers the password step with mfa_required and a pending session that does not authenticate yet" do
    login!

    expect(response).to have_http_status(:ok)
    expect(json).to include("mfa_required" => true)
    expect(OperatorSession.find(json["session_id"]).mfa_verified_at).to be_nil

    get "/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "completes the login with a valid TOTP and audits it on the platform" do
    login!
    session_id = json["session_id"]

    expect {
      post "/session/challenge", params: { session_id: session_id, code: totp }
    }.to change { PlatformEvent.where(name: "operator.login").count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(json).to include("id" => operator.id, "email_address" => operator.email_address,
                            "operator" => true, "mfa_enrolled" => true, "memberships" => [])
    expect(json["mfa_verified_at"]).to be_present
    expect(PlatformEvent.where(name: "operator.login").order(:occurred_at).last.payload)
      .to eq("operator_id" => operator.id, "operator_session_id" => session_id)

    get "/session"
    expect(response).to have_http_status(:ok)
    expect(json["id"]).to eq(operator.id)
  end

  it "keeps the session pending if auditing the login fails, so an unaudited login never authenticates" do
    login!
    session_id = json["session_id"]

    allow(Platform).to receive(:audit).and_raise(ActiveRecord::StatementInvalid, "boom")

    expect {
      post "/session/challenge", params: { session_id: session_id, code: totp }
    }.to raise_error(ActiveRecord::StatementInvalid)

    expect(OperatorSession.find(session_id).mfa_verified_at).to be_nil

    get "/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a wrong TOTP and keeps the session unauthenticated" do
    login!

    post "/session/challenge", params: { session_id: json["session_id"], code: "nao-e-um-codigo" }

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_code")
    get "/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a challenge for a pending session that is not the one in this client's cookie" do
    other = create_operator("outro")
    foreign = other.operator_sessions.create!(user_agent: "outro navegador")
    login! # planta o cookie da sessão pendente DESTE cliente

    post "/session/challenge", params: { session_id: foreign.id, code: totp(other) }

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_session")
    expect(foreign.reload.mfa_verified_at).to be_nil
  end

  it "refuses a challenge after the pending window" do
    login!
    session_id = json["session_id"]

    travel 11.minutes do
      post "/session/challenge", params: { session_id: session_id, code: totp }
    end

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_session")
  end

  it "refuses wrong password, unknown email and a deactivated operator alike" do
    login!(operator, "errada")
    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_credentials")

    post "/session", params: { email_address: "ninguem@rotasaude.app", password: password }
    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_credentials")

    operator.update!(deactivated_at: Time.current)
    login!
    expect(response).to have_http_status(:unauthorized)
    expect(OperatorSession.where(operator: operator)).to be_empty
  end

  it "refuses an array of email addresses instead of enumerating operator accounts" do
    post "/session", params: { email_address: [ "ninguem@x.app", operator.email_address ], password: password }

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_credentials")
    expect(OperatorSession.where(operator: operator)).to be_empty
  end

  it "refuses an array of passwords instead of enumerating operator accounts" do
    post "/session", params: { email_address: operator.email_address, password: [ "errada", password ] }

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "invalid_credentials")
    expect(OperatorSession.where(operator: operator)).to be_empty
  end

  it "still logs in with a mixed-case email (normalization kept)" do
    post "/session", params: { email_address: operator.email_address.upcase, password: password }

    expect(response).to have_http_status(:ok)
    expect(json).to include("mfa_required" => true)
  end

  it "refuses an operator without MFA before creating any session" do
    operator.update!(otp_enabled: false)

    login!

    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "mfa_enrollment_required")
    expect(OperatorSession.where(operator: operator)).to be_empty
  end

  it "logs out: destroys the session and the cookie stops authenticating" do
    verified_login!
    session_id = OperatorSession.where(operator: operator).sole.id

    delete "/session"

    expect(response).to have_http_status(:no_content)
    expect(OperatorSession.exists?(session_id)).to be(false)
    get "/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "clears a pending (not yet MFA-verified) operator session on logout" do
    login!
    session_id = json["session_id"]

    delete "/session"

    expect(response).to have_http_status(:no_content)
    expect(OperatorSession.exists?(session_id)).to be(false)

    get "/session"
    expect(response).to have_http_status(:unauthorized)
  end

  it "logs out without raising when there is no operator cookie at all" do
    delete "/session"

    expect(response).to have_http_status(:no_content)
  end

  it "sets a host-only operator cookie (never a Domain attribute)" do
    login!

    expect(set_cookie_header).to match(/operator_session_id=/)
    expect(set_cookie_header).not_to match(/domain=/i)
  end

  it "still authenticates a verified session within the 12h server TTL (positive control)" do
    verified_login!

    travel 11.hours do
      get "/session"
    end

    expect(response).to have_http_status(:ok)
  end

  it "expires a verified session on the server after 12 hours, even though the cookie itself never expired" do
    verified_login!

    travel 12.hours + 1.minute do
      get "/session"
    end

    expect(response).to have_http_status(:unauthorized)
  end

  it "operator controllers never resolve a city" do
    expect(Operators::BaseController.ancestors).not_to include(CityResolution)
    expect(Operators::BaseController.ancestors).not_to include(Authentication)
  end

  describe "host isolation" do
    def verified_cookie
      verified_login!
      set_cookie_header[/operator_session_id=[^;]+/]
    end

    it "a verified operator cookie does not authenticate on a city host" do
      cookie = verified_cookie

      get "/session", headers: { "HOST" => test_city_host, "Cookie" => cookie }

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "unauthenticated")
    end

    it "operator credentials are not city credentials" do
      post "/session", params: { email_address: operator.email_address, password: password },
                       headers: { "HOST" => test_city_host }

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "invalid_credentials")
    end

    it "the console host serves no city API, even to a verified operator" do
      cookie = verified_cookie

      get "/admin/api/overview", headers: { "Cookie" => cookie }

      expect(response).to have_http_status(:not_found)
      expect(json).to eq("error" => "unknown_city")
    end
  end

  describe "deactivation and replay" do
    it "refuses a verified session once the operator is deactivated" do
      verified_login!

      operator.update!(deactivated_at: Time.current)

      get "/session"
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses the challenge if the operator was deactivated after the password step" do
      login!
      session_id = json["session_id"]

      operator.update!(deactivated_at: Time.current)

      post "/session/challenge", params: { session_id: session_id, code: totp }

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "invalid_session")
      expect(OperatorSession.find(session_id).mfa_verified_at).to be_nil
    end

    it "refuses to re-challenge an already verified session, and does not audit a second login" do
      login!
      session_id = json["session_id"]
      post "/session/challenge", params: { session_id: session_id, code: totp }
      expect(response).to have_http_status(:ok)

      expect {
        post "/session/challenge", params: { session_id: session_id, code: totp }
      }.not_to change { PlatformEvent.where(name: "operator.login").count }

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "invalid_session")
    end

    it "refuses a challenge for a pending session id when this client has no operator cookie at all" do
      session = operator.operator_sessions.create!(user_agent: "sem cookie")

      post "/session/challenge", params: { session_id: session.id, code: totp }

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "invalid_session")
      expect(session.reload.mfa_verified_at).to be_nil
    end

    it "refuses a challenge with a blank session_id even with the pending cookie present" do
      login!

      post "/session/challenge", params: { session_id: "", code: totp }

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "invalid_session")
    end
  end

  # Defesa em profundidade: se uma rota nova esquecer a constraint do console,
  # o controller de operador continua recusando host de cidade.
  describe "an operator route drawn without the console constraint" do
    before(:all) do
      Rails.application.routes.disable_clear_and_finalize = true
      Rails.application.routes.draw do
        get "/_operator_session_without_constraint", to: "operators/sessions#show"
      end
    end

    after(:all) do
      Rails.application.routes.disable_clear_and_finalize = false
      Rails.application.reload_routes!
    end

    it "answers 404 on a city host" do
      get "/_operator_session_without_constraint", headers: { "HOST" => test_city_host }

      expect(response).to have_http_status(:not_found)
    end
  end
end
