# Base das rotas /lab/* (ADR 0037; contrato §3–§6): sessão do dashboard e
# municipal_lab utilizável (que exige exam_tracking).
module Lab
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp

    UUID = Exams::BaseController::UUID
    FAILURE_STATUS = {
      invalid_transition: :conflict, gal_already_registered: :conflict, not_found: :not_found,
      missing_role: :forbidden, not_unit_staff: :forbidden, mfa_required: :unauthorized
    }.freeze

    before_action :require_municipal_lab!

    private

    def require_municipal_lab!
      return if Lab::Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: Lab::Gate::KEY }, status: :forbidden
    end

    def render_failure(result)
      payload = { error: result.reason.to_s }
      payload[:status] = result.details[:status] if result.reason == :invalid_transition && result.details[:status]
      payload[:analyte_key] = result.details[:analyte_key] if result.details[:analyte_key]
      payload[:barcode] = result.details[:barcode] if result.details[:barcode]
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def body_params = params.except(:controller, :action, :id).permit!.to_h

    # O laboratório do parâmetro: municipal, ativo e da sessão; senão 404/403.
    def provider_param!(key = :provider_id)
      @provider = uuid?(params[key]) && Lab::Access.labs.find_by(id: params[key])
      return not_found unless @provider

      forbid unless Lab::Access.member?(Current.user, @provider.id) || Lab::Access.admin?(Current.user) ||
                    Lab::Access.collecting_unit_ids(Current.user).any?
    end
  end
end
