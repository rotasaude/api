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

    payload = Mfa::Enroll.call(Current.user)
    render json: {
      otpauth_uri: payload[:otpauth_uri],
      recovery_codes: payload[:recovery_codes]   # mostrar uma vez, nunca mais
    }
  end

  def confirm
    # A2: confirmar a matrícula prova que o autenticador NOVO foi escaneado —
    # um recovery code (que nem existiria ainda no primeiro cadastro) não
    # pode ligar otp_enabled no lugar do TOTP.
    if Mfa::Verify.totp_valid?(Current.user, params[:code])
      Current.user.update!(otp_enabled: true)
      render json: { ok: true }
    else
      render json: { error: "invalid_code" }, status: :unprocessable_entity
    end
  end

  def step_up
    if Mfa::Verify.call(Current.user, code: params[:code])
      Current.session.update!(mfa_verified_at: Time.current)
      render json: { ok: true }
    else
      render json: { error: "invalid_code" }, status: :unprocessable_entity
    end
  end
end
