# Rotas do SNCR (ADR 0034; contrato §4, §6): interruptor controlled_prescriptions
# utilizável e papel de profissional (a recepção recebe 403 missing_role); o
# admin troca o before_action.
module Sncr
  class BaseController < ApplicationController
    include Authentication
    include AttendanceAccess
    include ControlledPrescriptionsGate

    wrap_parameters false

    ERROR_STATUS = {
      missing_role: :forbidden, cbo_not_allowed: :forbidden, authorization_denied: :forbidden, registration_mismatch: :forbidden,
      invalid_state: :unprocessable_entity, invalid_content: :unprocessable_entity,
      authorization_expired: :conflict, monthly_limit_reached: :conflict,
      sncr_unavailable: :service_unavailable, sncr_exhausted: :service_unavailable
    }.freeze

    before_action :require_controlled_prescriptions!
    before_action :require_professional

    private

    def failure(result) = render_failure(result, ERROR_STATUS)
    def body = params.to_unsafe_h.except("controller", "action", "id")
  end
end
