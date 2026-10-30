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

    before_action :require_clinical_record!, :require_dental_care!

    private

    # `{ error, path?, problems? }`: só quando o resultado traz.
    def render_failure(result)
      payload = { error: result.reason.to_s }
      %i[path problems].each { |key| payload[key] = result.details[key] if result.details[key] }
      render json: payload, status: FAILURE_STATUS.fetch(result.reason, :unprocessable_entity)
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
