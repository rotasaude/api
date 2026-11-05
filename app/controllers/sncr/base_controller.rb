# Rotas do SNCR (ADR 0034; contrato §4, §6): interruptor controlled_prescriptions
# utilizável e papel de profissional ou o do CAPS (a recepção recebe 403
# missing_role); o admin troca o before_action.
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

    # Módulo 31 (P56, R10; padrão do P47 em Signatures::BaseController): a
    # equipe do CAPS pede e consulta o PRÓPRIO estoque (por usuário; o
    # conselho CRM/CRO continua conferido em StartRequest e no saldo). O número
    # só sai em ClinicalDocuments::Issue, para documento de que ela é autora —
    # pela ação do CAPS, a única emissão aberta ao papel.
    def require_professional
      return if Psychosocial::Access.staff?(Current.user)

      super
    end
    def body = params.to_unsafe_h.except("controller", "action", "id")
  end
end
