# Base das rotas /psychosocial/* (ADR 0049): sessão do dashboard e
# `psychosocial_care` utilizável (403 feature_disabled; sem cascata, P22). Dado
# do paciente (CPF, CNS, nome, CID, texto clínico) só do corpo JSON, nunca da
# URL. O padrão do Tfd::BaseController.
module Psychosocial
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::PsychosocialGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Contrato P13 (ruling do controlador): conflitos no padrão do 30 (409);
    # papel e lotação 403; o resto das recusas é 422.
    FAILURE_STATUS = {
      enrollment_open: :conflict, bed_taken: :conflict, already_staying: :conflict, already_exported: :conflict,
      bed_label_taken: :conflict, already_closed: :conflict, already_cancelled: :conflict, month_open: :conflict,
      record_not_open: :conflict, referral_not_pending: :conflict,
      not_on_caps_team: :forbidden, missing_role: :forbidden, lead_required: :forbidden, not_author: :forbidden,
      out_of_context: :forbidden,
      not_found: :not_found
    }.freeze
    KEY_PATH_MAX = 64

    before_action :require_psychosocial!

    private

    # `{ error, path?, problems? }` e, na crítica da ação (P23), o topo
    # `action_rejected` com `problems: [ { error, path, participant_index? } ]`;
    # outras chaves de topo do resultado (night_limit_reached: used, limit,
    # window_days) vão junto.
    def render_failure(result)
      payload = { error: result.reason.to_s }.merge(result.details.except(:path, :problems))
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details.key?(key) }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    # 422 no formato uniforme: `error`/`path` no topo e `problems` com esse problema.
    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { error: error.to_s, path: path } ] }, status: :unprocessable_entity
    end

    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)
    def admin? = Current.user.has_role?("municipal_admin")

    # Equipe lotada no CAPS (Desvio 2): sem o papel do CAPS → 403 missing_role;
    # sem uuid ou fora dos CAPS ativos → 422 invalid_request `health_unit_id`;
    # sem vínculo ativo no CAPS → 403 not_on_caps_team. Devolve o CAPS e
    # guarda o vínculo (@link, o CBO da ação); renderiza e devolve nil quando recusa.
    def staff_unit!(health_unit_id)
      unless Access.staff?(Current.user)
        forbid("missing_role")
        return nil
      end

      unit = uuid?(health_unit_id) ? HealthUnit.find_by(id: health_unit_id, kind: "caps", active: true) : nil
      unless unit
        render_refusal("health_unit_id")
        return nil
      end

      @link = Access.link(Current.user, unit.id)
      unless @link
        forbid("not_on_caps_team")
        return nil
      end

      unit
    end

    # Coordenação do CAPS: sem o papel da equipe → missing_role; equipe sem
    # coordenação → lead_required. Renderiza e devolve false quando recusa.
    def require_lead!
      return true if Access.lead?(Current.user)

      forbid(Access.staff?(Current.user) ? "lead_required" : "missing_role")
      false
    end

    # Dado do paciente e texto livre só do corpo JSON: na query vale como ausente.
    def body_param(key) = request.request_parameters[key]
    def body = request.request_parameters.except("controller", "action", "id")

    # Rotas cujo dado sensível só vem no corpo: query com chave fora de
    # `allowed` → 422 invalid_request com o path (só o NOME da chave, truncado).
    def query_only!(*allowed)
      unknown = (request.query_parameters.keys - allowed.map(&:to_s)).first
      return true unless unknown

      render_refusal(unknown.to_s[0, KEY_PATH_MAX])
      false
    end
  end
end
