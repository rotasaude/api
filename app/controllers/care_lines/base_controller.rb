# Base das rotas /care_lines/* (ADR 0040; contrato §3–§6): sessão do
# dashboard e care_lines ligado e utilizável (403 feature_disabled).
module CareLines
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::CareLinesGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    FAILURE_STATUS = { invalid_transition: :conflict, already_enrolled: :conflict, citizen_not_verified: :conflict,
                       line_inactive: :conflict, already_scheduled: :conflict, cbo_not_allowed: :forbidden,
                       not_found: :not_found }.freeze

    before_action :require_care_lines!

    private

    def render_failure(result)
      payload = { error: result.reason.to_s }
      payload[:field] = result.details[:field] if result.details[:field]
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    # Módulo 29: as práticas de vacina só são medidas com `vaccination`
    # utilizável. Lido aqui, na requisição, fora de transação da cidade.
    def vaccination_usable? = Vaccination::Gate.usable?(Current.city)
    def body = params.to_unsafe_h.except("controller", "action", "id")
    # Dado de saúde e texto livre (DUM, nota, motivo) só do corpo JSON, nunca
    # da query string (URL vai para log de proxy e histórico): na query vale
    # como ausente. O padrão do declared_conditions_controller.
    def body_param(key) = request.request_parameters[key]

    # Equipe do pedido (team_id) dentro do escopo do profissional; fora dele,
    # 403 out_of_scope. Compartilhado pelos controllers de sugestões e inscrições.
    # A eSB (71) não é equipe de linha de cuidado: 404, como a desconhecida
    # na prévia (módulo 28, Review Focus 1).
    def scoped_team
      team = uuid?(params[:team_id]) && HealthTeam.find_by(id: params[:team_id])
      if team && !care_line_team?(team)
        not_found
      elsif Access.panel?(Current.user, team)
        return team
      else
        forbid("out_of_scope")
      end
      nil
    end

    def care_line_team?(team) = HealthTeam::PRIMARY_CARE_KINDS.include?(team.kind)
  end
end
