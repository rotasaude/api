# Base das rotas /dental/* (ADR 0046): sessão do dashboard, prontuário
# utilizável e `dental_care` ligado (403 feature_disabled). Dado do paciente e
# dado clínico (dente, face, situação, procedimento, periograma, endodontia,
# gestante), motivos e justificativas só do corpo JSON, nunca da URL.
module DentalCare
  class BaseController < ApplicationController
    include Authentication
    include MfaStepUp
    include ::ClinicalRecordGate
    include ::DentalCareGate

    wrap_parameters false

    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # O resto das recusas é 422.
    FAILURE_STATUS = { missing_role: :forbidden, not_author: :forbidden, out_of_context: :forbidden,
                       not_found: :not_found, invalid_transition: :conflict, already_installed: :conflict }.freeze

    DEFAULT_LIMIT = 50
    MAX_LIMIT = 100

    before_action :require_clinical_record!, :require_dental_care!

    private

    # `{ error, path?, problems? }`: só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
    end

    # 422 uniforme: `error`/`path` no topo e `problems` com ao menos esse problema.
    def render_refusal(path, error = "invalid_request")
      render json: { error: error.to_s, path: path, problems: [ { path: path, error: error.to_s } ] }, status: :unprocessable_entity
    end

    # Tamanho da página das listas: padrão 50, máximo 100; inválido → 422.
    # Devolve nil depois de responder.
    def page_limit
      raw = params[:limit]
      return DEFAULT_LIMIT if raw.blank?

      value = Integer(raw.to_s, 10, exception: false)
      return value if value && value.between?(1, MAX_LIMIT)

      render_refusal("limit", "invalid_limit")
      nil
    end

    # Cursor [iso8601(6), id] das listas por (created_at DESC, id DESC).
    def valid_cursor?(cursor)
      return false unless cursor.is_a?(Array) && cursor.size == 2 && uuid?(cursor.last)

      Time.iso8601(cursor.first)
      true
    rescue ArgumentError, TypeError
      false
    end

    # Leitura nominal de `patients/:id/...`: paciente (404), acesso do prontuário
    # (403 com o motivo) e, se o bloco devolver true, uma trilha dental. O bloco
    # valida os filtros e responde; devolve false quando já respondeu a recusa.
    def read_patient
      patient = uuid?(params[:id]) ? Patient.find_by(id: params[:id]) : nil
      return not_found unless patient

      grant = ClinicalRecord::Access.call(user: Current.user, patient: patient)
      return forbid(grant.reason.to_s) unless grant.allowed?

      DentalCare::Trail.viewed!(patient: patient, user: Current.user, grant: grant) if yield(patient)
    end

    def render_error(reason, status = :unprocessable_entity) = render(json: { error: reason.to_s }, status: status)
    def forbid(reason = "missing_role") = render(json: { error: reason }, status: :forbidden)
    def not_found = render(json: { error: "not_found" }, status: :not_found)
    def uuid?(value) = value.is_a?(String) && value.match?(UUID)

    # Dado clínico e texto livre só do corpo JSON: na query vale como ausente.
    def body = request.request_parameters.except("controller", "action", "id")

    def admin? = Current.user.has_role?("municipal_admin")
    def panel_reader? = admin? || Current.user.has_role?("analyst")
  end
end
