class MfaController < ApplicationController
  include Authentication
  include MfaStepUp

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
