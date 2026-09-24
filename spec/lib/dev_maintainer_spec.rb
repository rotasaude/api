require "rails_helper"
require Rails.root.join("lib/dev_maintainer").to_s

# A semente que torna o console de manutenção acessível em dev. O `db/seeds.rb`
# semeava o Operator (console, host admin.*) e os usuários de cidade, mas nunca
# um Maintainer — que é outra tabela, de propósito (ver Maintainer §topo). Sem
# isto não existe credencial reproduzível para apps/maintenance: as contas de
# mantenedor em dev nasciam do `maintainer:invite`, com senha e TOTP que só
# quem rodou o convite conhecia.
#
# O exemplo que importa percorre o login DE VERDADE (senha + TOTP), porque é
# exatamente o que falhava: uma conta que "parece semeada" mas não loga não
# conserta nada.
RSpec.describe DevMaintainer, type: :request do
  let(:password) { "dev-password" }
  let(:frontend) { "https://maintenance.rotasaude.app" }

  def json = JSON.parse(response.body)
  def headers = { "Origin" => frontend, "X-Rota-Maintenance" => "1" }

  before do
    host! "maintenance-api.rotasaude.app"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("MAINTENANCE_FRONTEND_ORIGIN").and_return(frontend)
  end

  it "cria um mantenedor que consegue logar de verdade, senha e TOTP" do
    maintainer = described_class.ensure!(email_address: "dev@local", password: password)

    expect(maintainer).to be_enrolled

    post "/session", params: { email_address: "dev@local", password: password }, headers: headers
    expect(response).to have_http_status(:ok)

    post "/session/challenge",
         params: { session_id: json["session_id"], code: ROTP::TOTP.new(maintainer.otp_secret).now },
         headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "é idempotente: rodar de novo mantém o mesmo segredo" do
    first = described_class.ensure!(email_address: "dev@local", password: password)
    secret = first.otp_secret

    again = described_class.ensure!(email_address: "dev@local", password: password)

    expect(again.id).to eq(first.id)
    expect(again.otp_secret).to eq(secret)
  end

  it "nunca sobrescreve o TOTP de um mantenedor que já tem o seu" do
    mine = ROTP::Base32.random
    Maintainer.create!(email_address: "dev@local", password: "outra-senha", otp_secret: mine,
                       otp_enabled_at: Time.current)

    described_class.ensure!(email_address: "dev@local", password: password)

    expect(Maintainer.find_by(email_address: "dev@local").otp_secret).to eq(mine)
  end

  it "destrava a conta bloqueada e reativa a desativada — senão a semente não devolve o acesso" do
    Maintainer.create!(email_address: "dev@local", password: password, otp_secret: ROTP::Base32.random,
                       otp_enabled_at: Time.current, failed_attempts: Maintainer::LOCKOUT_ATTEMPTS,
                       locked_until: 10.minutes.from_now, deactivated_at: Time.current)

    maintainer = described_class.ensure!(email_address: "dev@local", password: password)

    expect(maintainer).not_to be_locked
    expect(maintainer.failed_attempts).to eq(0)
    expect(maintainer).to be_active
  end

  it "devolve o otpauth:// para o autenticador, com o e-mail da conta" do
    maintainer = described_class.ensure!(email_address: "dev@local", password: password)

    uri = described_class.otpauth_uri(maintainer)

    expect(uri).to start_with("otpauth://totp/")
    expect(uri).to include(CGI.escape(maintainer.otp_secret))
  end
end
