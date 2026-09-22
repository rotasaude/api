require "rails_helper"

RSpec.describe MfaController, type: :request do
  let!(:user) { User.create!(email_address: "dan@example.org", password: "secret123") }

  before do
    @enroll = Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    @session = user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
    allow_any_instance_of(MfaController).to receive(:resume_session) do
      Current.session = @session
    end
  end

  it "step_up com TOTP correto carimba mfa_verified_at" do
    code = ROTP::TOTP.new(user.otp_secret).now
    post "/mfa/step_up", params: { code: code }, as: :json
    expect(response).to have_http_status(:ok)
    expect(@session.reload.mfa_verified_at).to be_within(5.seconds).of(Time.current)
  end

  # A2: confirmar a matrícula prova que o autenticador NOVO foi escaneado —
  # um recovery code (do pendente) não serve para isso.
  describe "#confirm" do
    let!(:fresh_user) { User.create!(email_address: "erin@example.org", password: "secret123") }
    let!(:fresh_session) { fresh_user.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1") }

    before do
      allow_any_instance_of(MfaController).to receive(:resume_session) do
        Current.session = fresh_session
      end
      @fresh_enroll = Mfa::PendingEnrollment.start(fresh_user)
    end

    it "recusa um recovery code e não liga otp_enabled" do
      recovery_code = @fresh_enroll[:recovery_codes].first

      post "/mfa/confirm", params: { code: recovery_code }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to eq("error" => "invalid_code")
      expect(fresh_user.reload.otp_enabled).to be(false)
    end

    it "aceita o TOTP e liga otp_enabled" do
      code = ROTP::TOTP.new(fresh_user.reload.otp_pending_secret).now

      post "/mfa/confirm", params: { code: code }, as: :json

      expect(response).to have_http_status(:ok)
      expect(fresh_user.reload.otp_enabled).to be(true)
    end
  end

  # A1: mirror SessionsController's rate_limit; test env cache is :null_store
  # (nunca conta), então trocamos por um MemoryStore real só neste describe.
  describe "rate limiting" do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "caps mfa actions at 10 within the window: the 11th step_up gets 429" do
      # Um código de TOTP só vale uma vez (Task 2): repetir o mesmo pelas 10
      # chamadas cairia em code_reused antes do teto. Os dez recovery codes
      # são igualmente single-use e provam o mesmo limite sem tocar nisso.
      codes = @enroll[:recovery_codes]
      codes.each { |code| post "/mfa/step_up", params: { code: code }, as: :json }
      expect(response).to have_http_status(:ok)

      post "/mfa/step_up", params: { code: codes.last }, as: :json

      expect(response).to have_http_status(:too_many_requests)
      expect(JSON.parse(response.body)).to eq("error" => "too_many_requests")
    end
  end
end
