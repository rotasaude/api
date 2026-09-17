require "rails_helper"

# Spec da API de manutenção §6: o mantenedor nasce de um convite de uso único,
# válido por 24h, e só passa a logar com senha DEFINIDA e TOTP CONFIRMADO.
RSpec.describe "Maintainer invitation", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:maintainer) { Maintainer.create!(email_address: "conv-#{SecureRandom.hex(3)}@rotasaude.app") }
  let(:issued) { MaintainerInvitation.issue!(maintainer: maintainer) }
  let(:invitation) { issued.first }
  let(:token) { issued.last }

  def headers = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAINTENANCE_FRONTEND_ORIGIN").and_return(frontend)
  end

  it "hands the enrollment material once and accepts password plus a confirmed TOTP" do
    get "/invitations/#{token}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(json).to include("email_address" => maintainer.email_address)
    expect(json["otpauth_uri"]).to include("otpauth://")

    code = ROTP::TOTP.new(maintainer.reload.otp_secret).now
    post "/invitations/#{token}/accept", params: { password: "s3nha-forte-1", code: code }, headers: headers

    expect(response).to have_http_status(:no_content)
    expect(maintainer.reload.enrolled?).to be(true)
    expect(invitation.reload.usable?).to be(false)
    expect(PlatformEvent.where(name: "maintenance.maintainer.accepted").count).to eq(1)
  end

  it "refuses a wrong TOTP, leaving the invitation usable and the account without a password" do
    get "/invitations/#{token}", headers: headers

    post "/invitations/#{token}/accept", params: { password: "s3nha-forte-1", code: "000000" }, headers: headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(maintainer.reload.enrolled?).to be(false)
    expect(maintainer.password_digest).to be_nil
    expect(invitation.reload.usable?).to be(true)
  end

  it "refuses a used token, an expired one and an unknown one" do
    get "/invitations/#{token}", headers: headers
    code = ROTP::TOTP.new(maintainer.reload.otp_secret).now
    post "/invitations/#{token}/accept", params: { password: "s3nha-forte-1", code: code }, headers: headers
    expect(response).to have_http_status(:no_content)

    post "/invitations/#{token}/accept", params: { password: "outra-senha-9", code: code }, headers: headers
    expect(response).to have_http_status(:not_found)

    get "/invitations/token-que-nao-existe", headers: headers
    expect(response).to have_http_status(:not_found)

    other_maintainer = Maintainer.create!(email_address: "exp-#{SecureRandom.hex(3)}@rotasaude.app")
    _other, other_token = MaintainerInvitation.issue!(maintainer: other_maintainer)
    travel_to(MaintainerInvitation::TTL.from_now + 1.second) do
      get "/invitations/#{other_token}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
