# Base das rotas /home_visits/* (módulo 24b, ADR 0052; contrato §6, §13):
# sessão do dashboard e `home_visits` utilizável (403 feature_disabled). Dado de
# pessoa e texto (motivo, medida, observação) só do corpo JSON, nunca da URL.
# Recusas `{ error, path?, candidates? }` (plano, Desvio 11; pre-flight 3.3).
module HomeVisits
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::HomeVisitsGate
    include ::FieldListQuery

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422 (inclusive o cbo_not_allowed da atribuição,
    # que o controlador dela sobrescreve).
    FAILURE_STATUS = {
      day_changed: :conflict, day_closed: :conflict, visit_changed: :conflict, activity_changed: :conflict,
      duplicate_suspected: :conflict, cpf_taken: :conflict, cns_taken: :conflict, already_assigned: :conflict,
      citizen_not_verified: :conflict, assignment_already_ended: :conflict, device_already_revoked: :conflict,
      identity_locked: :conflict, client_uuid_conflict: :conflict,
      cbo_not_allowed: :forbidden, out_of_scope: :forbidden,
      not_found: :not_found, person_not_found: :not_found,
      too_many_requests: :too_many_requests
    }.freeze

    before_action :require_home_visits!

    private

    # `{ error, path?, candidates? }`, com o status do mapa (ou o de `status:`
    # para os códigos que a rota responde de outro jeito).
    def render_failure(result, status: {})
      payload = { error: result.reason.to_s }
      %i[path candidates].each { |key| payload[key] = result.details[key] if result.details.key?(key) }
      render json: payload, status: status.fetch(result.reason) { FAILURE_STATUS.fetch(result.reason, :unprocessable_entity) }
    end

    # Recusa direta do controlador, no mesmo formato.
    def render_refusal(error, path: nil, status: nil)
      payload = { error: error.to_s }
      payload[:path] = path if path
      render json: payload, status: status || FAILURE_STATUS.fetch(error.to_sym, :unprocessable_entity)
    end

    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Query com chave fora de `allowed` → 422 invalid_request, nada lido da URL.
    def query_only!(*allowed)
      return true if (request.query_parameters.keys - allowed.map(&:to_s)).empty?

      render_refusal("invalid_request")
      false
    end

    # Cursor opaco `before` (CareLines::Cursor): ausente → nil; inválido → 422
    # invalid_cursor (performed?).
    def cursor
      CareLines::Cursor.decode(params[:before])
    rescue CareLines::Cursor::Invalid
      render_refusal("invalid_cursor")
      nil
    end

    # A equipe de `team_id` (query ou corpo) em que o usuário tem vínculo ativo
    # (equipe ativa 70/76): sem id válido → 422 invalid_request (path team_id);
    # desconhecida ou fora da equipe → 403 out_of_scope. Guarda @team e
    # @member; devolve a equipe ou nil (já respondeu).
    def load_team!(id = params[:team_id])
      unless uuid?(id)
        render_refusal("invalid_request", path: "team_id")
        return nil
      end

      team = HealthTeam.includes(:health_unit).find_by(id: id)
      member = team && Access.member(Current.user, team)
      unless member
        render_refusal("out_of_scope")
        return nil
      end

      @member = member
      @team = team
    end
  end
end
