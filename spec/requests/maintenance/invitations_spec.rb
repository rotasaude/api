require "rails_helper"

# Spec da API de manutenção §6: o mantenedor nasce de um convite de uso único,
# válido por 24h, e só passa a logar com senha DEFINIDA e TOTP CONFIRMADO.
#
# Os dois passos são POST com o token no CORPO (fix round 1): um GET com o
# token no path apareceria em claro no log de acesso, e este token define
# senha e TOTP de um superusuário.
RSpec.describe "Maintainer invitation", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:frontend) { "https://maintenance.rotasaude.app" }
  let(:maintainer) { Maintainer.create!(email_address: "conv-#{SecureRandom.hex(3)}@rotasaude.app") }
  let(:issued) { MaintainerInvitation.issue!(maintainer: maintainer) }
  let(:invitation) { issued.first }
  let(:token) { issued.last }

  def headers = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }
  def json = JSON.parse(response.body)

  def enroll(tok = token)
    post "/invitations/enroll", params: { token: tok }, headers: headers
  end

  def accept(tok: token, password: "s3nha-forte-1", code:)
    post "/invitations/accept", params: { token: tok, password: password, code: code }, headers: headers
  end

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAINTENANCE_FRONTEND_ORIGIN").and_return(frontend)
  end

  it "hands the enrollment material once and accepts password plus a confirmed TOTP" do
    enroll
    expect(response).to have_http_status(:ok)
    expect(json).to include("email_address" => maintainer.email_address)
    expect(json["otpauth_uri"]).to include("otpauth://")

    code = ROTP::TOTP.new(maintainer.reload.otp_secret).now
    accept(code: code)

    expect(response).to have_http_status(:no_content)
    expect(maintainer.reload.enrolled?).to be(true)
    expect(invitation.reload.usable?).to be(false)
    expect(PlatformEvent.where(name: "maintenance.maintainer.accepted").count).to eq(1)
  end

  it "refuses a wrong TOTP, leaving the invitation usable and the account without a password" do
    enroll

    accept(code: "000000")

    expect(response).to have_http_status(:unprocessable_content)
    expect(maintainer.reload.enrolled?).to be(false)
    expect(maintainer.password_digest).to be_nil
    expect(invitation.reload.usable?).to be(true)
  end

  it "refuses a used token, an expired one and an unknown one" do
    enroll
    code = ROTP::TOTP.new(maintainer.reload.otp_secret).now
    accept(code: code)
    expect(response).to have_http_status(:no_content)

    accept(password: "outra-senha-9", code: code)
    expect(response).to have_http_status(:not_found)

    enroll("token-que-nao-existe")
    expect(response).to have_http_status(:not_found)

    other_maintainer = Maintainer.create!(email_address: "exp-#{SecureRandom.hex(3)}@rotasaude.app")
    _other, other_token = MaintainerInvitation.issue!(maintainer: other_maintainer)
    travel_to(MaintainerInvitation::TTL.from_now + 1.second) do
      enroll(other_token)
      expect(response).to have_http_status(:not_found)
    end
  end

  # Minor (fix round 1): mesmo caminho de 404 uniforme dos outros casos
  # inutilizáveis — não distingue "convite bom, conta desativada" de "convite
  # inexistente".
  it "refuses an invitation whose maintainer was deactivated" do
    maintainer.deactivate!

    enroll
    expect(response).to have_http_status(:not_found)

    accept(code: "000000")
    expect(response).to have_http_status(:not_found)
  end

  # Important #2 (fix round 1): convite é EXCLUSIVO — reconvidar supera
  # qualquer convite pendente anterior, mesmo um que ainda não venceu.
  it "refuses an older token once a re-invite issues a new one" do
    old_token = token
    MaintainerInvitation.invalidate_pending_for!(maintainer)
    _new_invitation, new_token = MaintainerInvitation.issue!(maintainer: maintainer)

    enroll(old_token)
    expect(response).to have_http_status(:not_found)

    enroll(new_token)
    expect(response).to have_http_status(:ok)
  end

  # Important #3 (fix round 1): recovery code também matricula, e o caminho
  # feliz precisa continuar funcionando com Mfa::Verify rodando dentro da
  # transação de aceite.
  it "accepts using a confirmed recovery code" do
    enroll
    recovery_code = json["recovery_codes"].first

    accept(code: recovery_code)

    expect(response).to have_http_status(:no_content)
    expect(maintainer.reload.enrolled?).to be(true)
    expect(maintainer.otp_recovery_codes.size).to eq(Mfa::Enroll::RECOVERY_COUNT - 1)
  end

  # Important #3 (fix round 1): se algo mais falhar DENTRO da mesma transação
  # depois que o recovery code já foi verificado (e consumido em memória pelo
  # update! de Mfa::Verify), o rollback tem que devolver o código — nunca gasto
  # sem que a conta tenha sido matriculada de verdade.
  it "keeps a recovery code unspent when something else fails inside the accept transaction" do
    enroll
    recovery_code = json["recovery_codes"].first
    codes_before = maintainer.reload.otp_recovery_codes.dup

    allow(MaintenanceAudit).to receive(:record).and_raise(ActiveRecord::Rollback)

    accept(code: recovery_code)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json).to include("error" => "invalid_code")
    expect(maintainer.reload.otp_recovery_codes).to eq(codes_before)
    expect(maintainer.password_digest).to be_nil
    expect(invitation.reload.usable?).to be(true)
  end
end
