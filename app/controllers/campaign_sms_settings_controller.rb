# app/controllers/campaign_sms_settings_controller.rb
# Chave de SMS da cidade (spec 2026-09-29 §6.1): campaign_manager e
# municipal_admin leem; só o municipal_admin muda, com step-up.
class CampaignSmsSettingsController < ApplicationController
  include Authentication
  include MfaStepUp

  wrap_parameters false

  def show
    return forbid unless policy.read_sms_setting?

    render json: setting_json
  end

  def update
    return forbid unless policy.write_sms_setting?
    return require_step_up! unless reauthenticated_recently?

    enabled = request.request_parameters["enabled"]
    return render(json: { error: "invalid_setting" }, status: :unprocessable_entity) unless [ true, false ].include?(enabled)

    result = Campaigns::SetSmsEnabled.call(enabled: enabled, by: Current.user)
    return render(json: { error: result.reason.to_s }, status: :conflict) if result.failure?

    render json: setting_json
  end

  private

  def policy
    CampaignPolicy.new(Current.user, nil)
  end

  def forbid
    render json: { error: "missing_role" }, status: :forbidden
  end

  def setting_json
    { enabled: Campaigns::SmsSetting.enabled?, gateway_configured: SmsGateway.configured? }
  end
end
