require "rails_helper"

# Spec do aviso de código de recuperação (2026-09-23-recovery-code-notice §6).
# Só o step-up aprovado por CÓDIGO DE RECUPERAÇÃO avisa; TOTP e recusa não.
RSpec.describe "MFA recovery code notice", type: :request do
  include ActiveJob::TestHelper

  def json = JSON.parse(response.body)
  def deliveries = ActionMailer::Base.deliveries

  let!(:user) { User.create!(email_address: "eve-#{SecureRandom.hex(3)}@example.org", password: "secret123") }
  let(:codes) { @codes }

  before do
    @codes = Mfa::Enroll.call(user)[:recovery_codes]
    user.update!(otp_enabled: true)
    deliveries.clear
  end

  def step_up!(code)
    perform_enqueued_jobs { post "/mfa/step_up", params: { code: code }, as: :json }
  end

  it "código de recuperação: um aviso, com a contagem que sobrou" do
    session = sign_in_as(user)

    step_up!(codes.first)

    expect(response).to have_http_status(:ok)
    expect(session.reload.mfa_verified_at).to be_within(5.seconds).of(Time.current)
    expect(deliveries.size).to eq(1)
    expect(deliveries.first.to).to eq([ user.email_address ])
    expect(deliveries.first.subject).to eq("[rota-saúde] Código de recuperação usado")
    body = deliveries.first.text_part.body.decoded
    expect(body).to include("Restam #{user.reload.otp_recovery_codes.size} códigos")
    # F5 (final-fix-brief.md): até aqui só o spec de mailer provava cidade e
    # IP no corpo, com literais — nunca a ponta a ponta a partir da
    # requisição real. `request.remote_ip` é o valor que o Rails reportou
    # para ESTA requisição de teste, não um literal inventado.
    expect(body).to include(City.find_by!(slug: TEST_CITY_A.slug).name)
    expect(body).to include(request.remote_ip)
  end

  it "TOTP não avisa" do
    sign_in_as(user)

    step_up!(ROTP::TOTP.new(user.reload.otp_secret).now)

    expect(response).to have_http_status(:ok)
    expect(deliveries).to be_empty
  end

  it "código inválido não avisa" do
    sign_in_as(user)

    step_up!("000000")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "invalid_code")
    expect(deliveries).to be_empty
  end

  it "código de recuperação já usado não avisa de novo" do
    sign_in_as(user)
    step_up!(codes.first)
    deliveries.clear

    step_up!(codes.first)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(deliveries).to be_empty
  end

  it "último código: aviso dizendo que só o autenticador aprova" do
    user.update!(otp_recovery_codes: user.otp_recovery_codes.first(1))
    sign_in_as(user)

    step_up!(codes.first)

    expect(deliveries.size).to eq(1)
    expect(deliveries.first.text_part.body.decoded).to include("Não resta nenhum código")
    expect(user.reload.otp_recovery_codes).to eq([])
  end

  it "falha ao enfileirar não descarimba a sessão nem muda a resposta" do
    session = sign_in_as(user)
    allow(SecurityMailer).to receive(:recovery_code_used).and_raise(StandardError, "fila fora do ar")

    step_up!(codes.first)

    expect(response).to have_http_status(:ok)
    expect(session.reload.mfa_verified_at).to be_present
  end

  # F2 (final-fix-brief.md): consumir um código compra uma janela de 5 minutos
  # para assinar, publicar, ativar, aposentar, reverter e gerir papéis — o
  # e-mail acima é o único vestígio hoje, e o rescue dele o engole se a fila
  # cair. DomainEvents.publish deixa rastro que sobrevive a isso (mesmo
  # precedente de Mfa::PendingEnrollment#confirm, ver
  # spec/services/mfa/pending_enrollment_spec.rb).
  it "código de recuperação: publica exatamente um user.recovery_code_used com o id do usuário" do
    sign_in_as(user)

    expect { step_up!(codes.first) }
      .to change { DomainEvent.where(name: "user.recovery_code_used").count }.by(1)

    event = DomainEvent.where(name: "user.recovery_code_used").sole
    expect(event.payload).to eq("user_id" => user.id, "remaining" => user.reload.otp_recovery_codes.size)
  end

  it "TOTP não publica user.recovery_code_used" do
    sign_in_as(user)

    expect { step_up!(ROTP::TOTP.new(user.reload.otp_secret).now) }
      .not_to change { DomainEvent.where(name: "user.recovery_code_used").count }
  end

  it "recusa não publica user.recovery_code_used" do
    sign_in_as(user)

    expect { step_up!("000000") }
      .not_to change { DomainEvent.where(name: "user.recovery_code_used").count }
  end

  it "o TOTP continua sendo consumido uma vez só" do
    sign_in_as(user)
    code = ROTP::TOTP.new(user.reload.otp_secret).now
    step_up!(code)
    expect(response).to have_http_status(:ok)

    step_up!(code)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json).to eq("error" => "code_reused")
    expect(deliveries).to be_empty
  end
end
