# Publicação de protocolo exige step-up de MFA (ADR-0022 + ADR-0016).
class PublicationsController < ApplicationController
  include Authentication
  include MfaStepUp

  def create
    return require_step_up! unless reauthenticated_recently?(via: :totp)

    result = Protocols::Publish.call(version: params[:version], by: Current.user)

    case result&.reason
    when nil
      render json: { ok: true, id: result.payload[:protocol_definition].id }
    when :not_found
      head :not_found
    when :forbidden
      render json: { error: "forbidden" }, status: :forbidden
    when :tenant_missing
      render json: { error: "tenant_missing" }, status: :unprocessable_entity
    else
      render json: { error: result.reason.to_s, message: result.message }, status: :unprocessable_entity
    end
  end
end
