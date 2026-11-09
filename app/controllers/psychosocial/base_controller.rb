# Base das rotas /psychosocial/* (ADR 0049): sessão do dashboard e
# `psychosocial_care` utilizável (403 feature_disabled; sem cascata, P22). Dado
# do paciente (CPF, CNS, nome, CID, texto clínico) só do corpo JSON, nunca da
# URL. O padrão do Tfd::BaseController.
module Psychosocial
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::PsychosocialGate
    include ::MonthParam

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # Contrato P13 (ruling do controlador): conflitos no padrão do 30 (409);
    # papel e lotação 403; o resto das recusas é 422.
    FAILURE_STATUS = {
      enrollment_open: :conflict, bed_taken: :conflict, already_staying: :conflict, already_exported: :conflict,
      bed_label_taken: :conflict, already_closed: :conflict, already_cancelled: :conflict, month_open: :conflict,
      record_not_open: :conflict, referral_not_pending: :conflict, night_stay_open: :conflict,
      not_on_caps_team: :forbidden, missing_role: :forbidden, lead_required: :forbidden, not_author: :forbidden,
      out_of_context: :forbidden,
      nothing_to_export: :unprocessable_entity, started_after_actions: :unprocessable_entity,
      not_found: :not_found
    }.freeze
    KEY_PATH_MAX = 64
    # Chaves de `details` que sobem ao topo da recusa (lista de permissão):
    # o limite do acolhimento noturno (P13: used, limit, window_days; `rule`
    # é o extra do plano, P6). Qualquer outra chave fica fora da resposta.
    TOP_LEVEL_DETAILS = %i[used limit window_days rule].freeze

    before_action :require_psychosocial!

    private

    # `{ error, path?, problems? }` e, na crítica da ação (P23), o topo
    # `action_rejected` com `problems: [ { error, path, participant_index? } ]`;
    # das demais chaves do resultado, só as de TOP_LEVEL_DETAILS.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      (TOP_LEVEL_DETAILS + %i[path problems]).each { |key| payload[key] = result.details[key] if result.details.key?(key) }
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

    # Remessa RAAS e fichas espelho (contrato §6, P15): a coordenação lotada no
    # CAPS ou o faturista (qualquer CAPS, sem lotação). Sem nenhum dos dois
    # papéis → 403 lead_required (equipe) ou missing_role; sem uuid ou fora dos
    # CAPS (ativos, salvo active_only: false — a remessa de CAPS desativado
    # continua listável e baixável, ruling) → 422 invalid_request
    # `health_unit_id`; coordenação sem vínculo no CAPS → 403 not_on_caps_team.
    # Renderiza e devolve nil quando recusa.
    def raas_unit!(health_unit_id, active_only: true)
      return unless raas_role!

      scope = HealthUnit.where(kind: "caps")
      scope = scope.where(active: true) if active_only
      unit = uuid?(health_unit_id) ? scope.find_by(id: health_unit_id) : nil
      unless unit
        render_refusal("health_unit_id")
        return nil
      end
      return unit if raas_reader?(unit.id)

      forbid("not_on_caps_team")
      nil
    end

    # Papel da remessa e das fichas: renderiza a recusa e devolve false sem ele.
    def raas_role!
      return true if Access.billing_clerk?(Current.user) || Access.lead?(Current.user)

      forbid(Access.staff?(Current.user) ? "lead_required" : "missing_role")
      false
    end

    # Faturista em qualquer CAPS; coordenação só onde está lotada.
    def raas_reader?(health_unit_id)
      Access.billing_clerk?(Current.user) || (Access.lead?(Current.user) && Access.link(Current.user, health_unit_id).present?)
    end

    # Matrícula da URL (`@enrollment`) para as rotas /enrollments/:id/...: sem o
    # papel do CAPS → 403 missing_role; id malformado, inexistente ou de CAPS em
    # que quem pede não está lotado → 404. Detalhe e escrita: nada na query.
    # Renderiza (e encerra a cadeia) quando recusa.
    def load_enrollment
      return forbid unless Access.staff?(Current.user)
      return unless query_only!

      @enrollment = uuid?(params[:id]) ? PsychosocialEnrollment.find_by(id: params[:id]) : nil
      not_found unless @enrollment && Access.can_read?(Current.user, @enrollment)
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
