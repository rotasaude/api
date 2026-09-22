require "rails_helper"

# Os endpoints de MFA do usuário da cidade (spec do autenticador pendente §4).
RSpec.describe "MFA pending enrollment", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def json = JSON.parse(response.body)

  let!(:user) { User.create!(email_address: "cau-#{SecureRandom.hex(3)}@example.org", password: "secret123") }

  def enroll!(stepped_up: false)
    session = sign_in_as(user)
    session.update!(mfa_verified_at: Time.current) if stepped_up
    post "/mfa/enroll", as: :json
    session
  end

  def pending_code = ROTP::TOTP.new(user.reload.otp_pending_secret).now

  it "primeiro cadastro: enroll propõe e confirm promove" do
    enroll!
    expect(response).to have_http_status(:ok)
    expect(user.reload.otp_secret).to be_nil
    expect(user.otp_pending_secret).to be_present

    post "/mfa/confirm", params: { code: pending_code }, as: :json

    expect(response).to have_http_status(:ok)
    expect(user.reload.otp_enabled).to be(true)
    expect(user.otp_secret).to be_present
    expect(user.otp_pending_secret).to be_nil
  end

  context "conta já cadastrada" do
    before do
      Mfa::Enroll.call(user)
      user.update!(otp_enabled: true)
    end

    it "enroll sem step-up continua recusado, e nada muda" do
      secret = user.reload.otp_secret
      enroll!

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(user.reload.otp_secret).to eq(secret)
      expect(user.otp_pending_secret).to be_nil
    end

    it "enroll com step-up propõe e o autenticador antigo continua valendo" do
      active_secret = user.reload.otp_secret
      enroll!(stepped_up: true)

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.otp_secret).to eq(active_secret)
      expect(user.otp_enabled).to be(true)
      expect(user.otp_pending_secret).to be_present
    end

    it "confirm promove e o segredo antigo para de valer" do
      enroll!(stepped_up: true)
      old_secret = user.reload.otp_secret

      post "/mfa/confirm", params: { code: pending_code }, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.otp_secret).not_to eq(old_secret)
    end

    it "confirm sem pendente responde no_pending_enrollment" do
      sign_in_as(user)

      post "/mfa/confirm", params: { code: "123456" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to eq("error" => "no_pending_enrollment")
    end

    it "confirm de um pendente vencido responde enrollment_expired" do
      enroll!(stepped_up: true)
      code = pending_code
      user.update!(otp_pending_at: 16.minutes.ago)

      post "/mfa/confirm", params: { code: code }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to eq("error" => "enrollment_expired")
    end

    it "confirm com código errado responde invalid_code" do
      enroll!(stepped_up: true)

      post "/mfa/confirm", params: { code: "000000" }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to eq("error" => "invalid_code")
    end
  end

  describe "step_up" do
    before do
      Mfa::Enroll.call(user)
      user.update!(otp_enabled: true)
    end

    it "aceita o TOTP e carimba a sessão" do
      session = sign_in_as(user)

      post "/mfa/step_up", params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }, as: :json

      expect(response).to have_http_status(:ok)
      expect(session.reload.mfa_verified_at).to be_within(5.seconds).of(Time.current)
    end

    it "recusa o MESMO código na segunda vez" do
      sign_in_as(user)
      code = ROTP::TOTP.new(user.reload.otp_secret).now
      post "/mfa/step_up", params: { code: code }, as: :json
      expect(response).to have_http_status(:ok)

      post "/mfa/step_up", params: { code: code }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to eq("error" => "code_reused")
    end

    it "continua aceitando um código de recuperação, uma vez só" do
      codes = Mfa::Enroll.call(user)[:recovery_codes]
      user.update!(otp_enabled: true)
      sign_in_as(user)

      post "/mfa/step_up", params: { code: codes.first }, as: :json
      expect(response).to have_http_status(:ok)

      post "/mfa/step_up", params: { code: codes.first }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json).to eq("error" => "invalid_code")
    end
  end
end
