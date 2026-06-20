# Publicação de protocolo exige step-up de MFA (ADR-0022 + ADR-0016).
class PublicationsController < ApplicationController
  include Authentication
  include MfaStepUp

  def create
    return require_step_up! unless reauthenticated_recently?(via: :totp)
    # Phase 4 traz authorize_publish_protocol! via policy
    Protocols::Publish.call(version: params[:version], by: Current.user)
    render json: { ok: true }
  end
end
