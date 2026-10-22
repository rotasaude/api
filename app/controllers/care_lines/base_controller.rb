# Base das rotas /care_lines/* (ADR 0040; contrato §3–§6): sessão do
# dashboard e care_lines ligado e utilizável (403 feature_disabled).
module CareLines
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    FAILURE_STATUS = { invalid_transition: :conflict, already_enrolled: :conflict, citizen_not_verified: :conflict,
                       line_inactive: :conflict, already_scheduled: :conflict, cbo_not_allowed: :forbidden,
                       not_found: :not_found }.freeze

    before_action :require_care_lines!

    private

    def require_care_lines!
      return if Gate.usable?(Current.city)

      render json: { error: "feature_disabled", feature: Gate::KEY }, status: :forbidden
    end

    def render_failure(result)
      payload = { error: result.reason.to_s }
      payload[:field] = result.details[:field] if result.details[:field]
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def body = params.to_unsafe_h.except("controller", "action", "id")

    # Equipe do pedido (team_id) dentro do escopo do profissional; fora dele,
    # 403 out_of_scope. Compartilhado pelos controllers de sugestões e inscrições.
    def scoped_team
      team = uuid?(params[:team_id]) && HealthTeam.find_by(id: params[:team_id])
      return team if Access.panel?(Current.user, team)

      forbid("out_of_scope")
      nil
    end
  end
end
