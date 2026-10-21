# Base das rotas /billing/* (ADR 0039; contrato §3–§6): sessão do dashboard
# e procedure_billing ligado (403 feature_disabled). Recusas no formato
# { error }; 409 para transição inválida, competência fechada e par não verificado.
module Billing
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp

    wrap_parameters false

    UUID = Exams::BaseController::UUID
    FAILURE_STATUS = { invalid_transition: :conflict, already_exported: :conflict, citizen_not_verified: :conflict, not_found: :not_found,
                       patient_not_found: :not_found, mfa_required: :unauthorized }.freeze

    before_action :require_billing!

    private

    def require_billing!
      return if Gate.enabled?(Current.city)

      render json: { error: "feature_disabled", feature: Gate::KEY }, status: :forbidden
    end

    def render_failure(result)
      payload = { error: result.reason.to_s }
      payload[:status] = result.details[:status] if result.details[:status]
      payload[:field] = result.details[:field] if result.details[:field]
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def invalid_filter = render_error(:invalid_filter)
    def invalid_establishment = render_error(:invalid_establishment)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
  end
end
