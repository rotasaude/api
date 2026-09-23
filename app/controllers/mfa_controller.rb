class MfaController < ApplicationController
  include Authentication
  include MfaStepUp

  # A1: `store:` de `rate_limit` é avaliado no CARREGAMENTO da classe — passar
  # `Rails.cache` direto congelaria o store daquele instante (o do ambiente de
  # teste é :null_store, que nunca conta). Mesmo delegador que
  # MaintainerAuthentication::CacheStore usa, pela mesma razão: resolve
  # Rails.cache a cada requisição, o que torna o teto exercitável em spec.
  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  rate_limit to: 10, within: 3.minutes, only: %i[enroll confirm step_up], name: "mfa",
             store: RateLimitStore,
             with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

  def enroll
    # Spec do dashboard §4.2: trocar o autenticador de uma conta que JÁ tem
    # TOTP exige step-up — senão a senha sozinha (ou uma sessão roubada)
    # substituiria o segundo fator. O primeiro cadastro não tem fator anterior
    # a pedir e segue só com a sessão.
    return require_step_up! if Current.user.mfa_enrolled? && !reauthenticated_recently?

    payload = Mfa::PendingEnrollment.start(Current.user)
    render json: {
      otpauth_uri: payload[:otpauth_uri],
      recovery_codes: payload[:recovery_codes]   # mostrar uma vez, nunca mais
    }
  end

  # A matrícula só vale depois daqui: é `confirm` que promove o pendente. O
  # autenticador anterior vale até esta linha passar.
  def confirm
    # ANTES do command: depois da promoção a conta sempre tem autenticador, e
    # este é o único ponto onde cadastro e troca se distinguem.
    replacing = Current.user.mfa_enrolled?

    outcome = Mfa::PendingEnrollment.confirm(Current.user, code: params[:code])
    if outcome == :ok
      notify_authenticator_change(replacing: replacing)
      return render(json: { ok: true })
    end

    # :no_pending_enrollment | :enrollment_expired | :invalid_code | :code_reused
    render json: { error: outcome.to_s }, status: :unprocessable_entity
  end

  def step_up
    return render(json: { error: "code_reused" }, status: :unprocessable_entity) if reused_totp?

    factor = step_up_factor
    return render(json: { error: "invalid_code" }, status: :unprocessable_entity) if factor.nil?

    # O carimbo vem primeiro: um aviso não pode sair se a sessão não valeu.
    Current.session.update!(mfa_verified_at: Time.current)
    record_and_notify_recovery_code_used if factor == :recovery
    render json: { ok: true }
  end

  private

  # Aviso ao dono da conta (spec 2026-09-23-authenticator-change-notice §3).
  # Roda DEPOIS de a promoção comitar — dentro da transação, um rollback
  # mandaria aviso de algo que não aconteceu.
  #
  # Nunca derruba a ação: quem confirmou já tem o autenticador novo, e um
  # servidor de e-mail fora do ar não pode transformar isso em 500. O log leva
  # o id do usuário, nunca o e-mail nem o IP (CityMailDeliveryJob já desliga
  # log_arguments para a mesma razão).
  def notify_authenticator_change(replacing:)
    SecurityMailer.authenticator_changed(
      email_address: Current.user.email_address,
      kind: replacing ? "replaced" : "enrolled",
      city_name: Current.city&.name.to_s,
      ip_address: safe_remote_ip,
      occurred_at: Time.current.iso8601
    ).deliver_later
  rescue StandardError => e
    Rails.logger.error("[mfa] aviso de autenticador não enfileirado para #{Current.user.id}: #{e.class}")
  end

  # F1: `request.remote_ip` (ActionDispatch::RemoteIp) levanta IpSpoofAttackError
  # — um StandardError — quando Client-IP e X-Forwarded-For divergem. Isolado
  # do resto de notify_authenticator_change para que esse erro nunca cancele o
  # aviso inteiro: degrada para "desconhecido" e o e-mail sai do mesmo jeito.
  def safe_remote_ip
    request.remote_ip
  rescue StandardError
    "desconhecido"
  end

  # TOTP do segredo ativo, consumido uma vez (User#consume_totp_step!), ou um
  # código de recuperação, consumido como sempre.
  def reused_totp?
    step = Mfa::Verify.totp_step_for(Current.user, params[:code])
    step.present? && !Current.user.consume_totp_step!(step)
  end

  # Qual fator aprovou o step-up: :totp, :recovery, ou nil quando nenhum.
  #
  # A ordem importa e o consumo também: `reused_totp?` (chamado antes, na ação)
  # já consumiu o passo do TOTP quando o código é de TOTP válido, então aqui a
  # checagem de TOTP é leitura pura (`totp_step_for`) e nunca consome de novo.
  # `consume_recovery_code` é o único consumo deste método, e só é tentado
  # quando o código não é um TOTP válido.
  def step_up_factor
    return :totp if Mfa::Verify.totp_step_for(Current.user, params[:code]).present?
    return :recovery if Mfa::Verify.consume_recovery_code(Current.user, params[:code])

    nil
  end

  # F2 (final-fix-brief.md): consumir um código de recuperação compra uma
  # janela de 5 minutos para assinar, publicar, ativar, aposentar, reverter e
  # gerir papéis — sem isto, o único vestígio era o e-mail, e o rescue dele
  # mesmo o engolia. Mesmo precedente de Mfa::PendingEnrollment#confirm (ver o
  # comentário lá): DomainEvents.publish, ato de usuário DE CIDADE. Publica
  # ANTES do e-mail e fica DE PROPÓSITO fora do rescue de
  # notify_recovery_code_used — falhar ao publicar é falha de verdade, não
  # algo para degradar. Mesma disciplina de dado do e-mail: só o id do usuário
  # e a contagem restante, nunca o código, nunca o e-mail, nunca o IP.
  def record_and_notify_recovery_code_used
    DomainEvents.publish("user.recovery_code_used",
                          user_id: Current.user.id,
                          remaining: Current.user.otp_recovery_codes.size)
    notify_recovery_code_used
  end

  # Aviso de uso de código de recuperação (spec 2026-09-23-recovery-code-notice
  # §3). Mesmas regras do aviso de autenticador: depois do carimbo, nunca
  # derruba a ação, log só com o id do usuário.
  #
  # `otp_recovery_codes` já está atualizado em memória: consume_recovery_code
  # regrava a lista no mesmo registro (`user.update!`).
  def notify_recovery_code_used
    SecurityMailer.recovery_code_used(
      email_address: Current.user.email_address,
      city_name: Current.city&.name.to_s,
      ip_address: safe_remote_ip,
      occurred_at: Time.current.iso8601,
      remaining: Current.user.otp_recovery_codes.size
    ).deliver_later
  rescue StandardError => e
    Rails.logger.error("[mfa] aviso de recovery code não enfileirado para #{Current.user.id}: #{e.class}")
  end
end
