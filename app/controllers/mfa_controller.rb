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

    if stepped_up?
      Current.session.update!(mfa_verified_at: Time.current)
      render json: { ok: true }
    else
      render json: { error: "invalid_code" }, status: :unprocessable_entity
    end
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
      ip_address: request.remote_ip,
      occurred_at: Time.current.iso8601
    ).deliver_later
  rescue StandardError => e
    Rails.logger.error("[mfa] aviso de autenticador não enfileirado para #{Current.user.id}: #{e.class}")
  end

  # TOTP do segredo ativo, consumido uma vez (User#consume_totp_step!), ou um
  # código de recuperação, consumido como sempre.
  def reused_totp?
    step = Mfa::Verify.totp_step_for(Current.user, params[:code])
    step.present? && !Current.user.consume_totp_step!(step)
  end

  # Atenção: `reused_totp?` já consome o passo quando o código é válido, então
  # este método não pode consumir de novo — só repete `totp_step_for`, que é
  # leitura pura.
  def stepped_up?
    Mfa::Verify.totp_step_for(Current.user, params[:code]).present? ||
      Mfa::Verify.consume_recovery_code(Current.user, params[:code])
  end
end
