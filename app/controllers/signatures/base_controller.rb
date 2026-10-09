# app/controllers/signatures/base_controller.rb
# Rotas da assinatura digital (ADR 0032; contrato). Interruptor utilizável e
# papel health_professional (a recepção recebe 403 missing_role); as rotas do
# admin e as de leitura de assinatura gravada trocam os before_actions.
module Signatures
  class BaseController < ApplicationController
    include Authentication
    include AttendanceAccess
    include DigitalSignatureGate
    include MfaStepUp

    wrap_parameters false

    ERROR_STATUS = {
      missing_role: :forbidden, not_author: :forbidden, authorization_denied: :forbidden, out_of_context: :forbidden,
      invalid_provider: :unprocessable_entity, invalid_state: :unprocessable_entity, invalid_reason: :unprocessable_entity,
      invalid_period: :unprocessable_entity, certificate_cpf_mismatch: :unprocessable_entity,
      certificate_expired: :unprocessable_entity, certificate_revoked: :unprocessable_entity,
      certificate_not_found: :unprocessable_entity, certificate_untrusted: :unprocessable_entity,
      authorization_expired: :conflict, certificate_not_linked: :conflict, nothing_pending: :conflict,
      not_pending: :conflict, professional_cpf_missing: :conflict,
      provider_unavailable: :service_unavailable, signer_unavailable: :service_unavailable
    }.freeze

    before_action :require_digital_signature!
    before_action :require_professional

    private

    def failure(result, overrides = {})
      if result.reason == :feature_disabled
        return render(json: { error: "feature_disabled", feature: Signatures::Gate::KEY }, status: :forbidden)
      end

      render_failure(result, ERROR_STATUS.merge(overrides))
    end

    def body = params.to_unsafe_h.except("controller", "action", "id")
  end
end
