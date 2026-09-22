require "rails_helper"

# Spec do dashboard §4.2: trocar o autenticador de uma conta que JÁ tem TOTP
# exige step-up. Sem isso, quem tivesse só a senha (ou uma sessão roubada)
# cadastraria o próprio autenticador e passaria a fazer step-up — o segundo
# fator viraria enfeite. O primeiro cadastro continua só com a sessão: não há
# fator anterior a pedir.
RSpec.describe "MFA enroll with step-up", type: :request do
  def json = JSON.parse(response.body)

  let!(:user) { User.create!(email_address: "eve-#{SecureRandom.hex(3)}@example.org", password: "secret123") }

  it "primeiro cadastro não pede step-up" do
    sign_in_as(user)

    post "/mfa/enroll", as: :json

    expect(response).to have_http_status(:ok)
    expect(json["otpauth_uri"]).to start_with("otpauth://totp/")
  end

  it "conta ativa com cadastro pendente continua exigindo step-up" do
    Mfa::Enroll.call(user)
    user.update!(otp_enabled: true)
    session = sign_in_as(user)
    session.update!(mfa_verified_at: 1.minute.ago)

    post "/mfa/enroll", as: :json
    expect(response).to have_http_status(:ok)
    expect(user.reload.otp_pending_secret).to be_present

    session.update!(mfa_verified_at: nil)

    post "/mfa/enroll", as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(json).to eq("error" => "mfa_required")
  end

  context "conta com autenticador ativo" do
    before do
      Mfa::Enroll.call(user)
      user.update!(otp_enabled: true)
    end

    it "sem janela de step-up recusa com mfa_required e não mexe no segredo" do
      secret = user.reload.otp_secret
      sign_in_as(user)

      post "/mfa/enroll", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
      expect(user.reload.otp_secret).to eq(secret)
      expect(user.otp_enabled).to be(true)
    end

    it "com a janela vencida (6 min) também recusa" do
      sign_in_as(user).update!(mfa_verified_at: 6.minutes.ago)

      post "/mfa/enroll", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json).to eq("error" => "mfa_required")
    end

    it "com a janela aberta propõe o autenticador novo sem trocar o ativo" do
      secret = user.reload.otp_secret
      sign_in_as(user).update!(mfa_verified_at: 1.minute.ago)

      post "/mfa/enroll", as: :json

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.otp_secret).to eq(secret)
      expect(user.otp_pending_secret).to be_present
      expect(user.otp_pending_secret).not_to eq(secret)
    end
  end
end
