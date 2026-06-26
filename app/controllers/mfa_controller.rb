class MfaController < ApplicationController
  skip_tenant_scope
  include Authentication

  def enroll
    payload = Mfa::Enroll.call(Current.user)
    render json: {
      otpauth_uri: payload[:otpauth_uri],
      recovery_codes: payload[:recovery_codes]   # mostrar uma vez, nunca mais
    }
  end

  def confirm
    if Mfa::Verify.call(Current.user, code: params[:code])
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
