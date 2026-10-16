# Base das rotas /exams/* (ADR 0036; contrato §3–§6): sessão do dashboard,
# interruptor exam_tracking utilizável e a tradução de Result para JSON.
module Exams
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    FAILURE_STATUS = {
      invalid_transition: :conflict, conflict: :conflict, citizen_not_verified: :conflict, already_acknowledged: :conflict,
      not_found: :not_found,
      missing_role: :forbidden, not_requester: :forbidden, not_in_team: :forbidden, not_unit_staff: :forbidden,
      out_of_context: :forbidden, opening_required: :forbidden
    }.freeze

    before_action :require_exam_tracking!

    private

    def require_exam_tracking!
      return if Exams::Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: Exams::Gate::KEY }, status: :forbidden
    end

    def render_failure(result)
      payload = { error: result.reason.to_s }
      payload[:status] = result.details[:status] if result.reason == :invalid_transition
      payload[:details] = result.details[:paths] if result.details[:paths]
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def forbid(reason = "forbidden") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def limit_param = Timeline::Query.limit(params[:limit]) # 1..100, padrão 50
    def body_params = params.except(:controller, :action, :id).permit!.to_h
  end
end
