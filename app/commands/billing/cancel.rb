# Cancelamento do procedimento (contrato §3; B8): motivo 10..500 (cifrado), uma
# vez só (trigger). Procedimento que entrou no arquivo de competência
# fechada: 409 already_exported (reabra a competência antes). Travas na ordem
# do módulo: competência (FOR SHARE) → procedimento.
module Billing
  module Cancel
    module_function

    def call(procedure:, reason:, by:, now: Time.current)
      text = reason.is_a?(String) ? reason.strip : ""
      return Result.fail(:reason_required) unless text.length.between?(10, 500)

      ApplicationRecord.transaction do
        period = procedure.billing_period_id && BillingPeriod.lock("FOR SHARE").find(procedure.billing_period_id)
        procedure.lock!
        next Result.fail(:invalid_transition, details: { status: procedure.status }) unless procedure.status == "recorded"
        next Result.fail(:already_exported) if period&.closed? && procedure.billing_export_id

        procedure.update!(status: "cancelled", cancel_reason: text, cancelled_at: now, cancelled_by_user: by)
        DomainEvents.publish("performed_procedure.cancelled", performed_procedure_id: procedure.id)
        Result.ok(procedure: procedure)
      end
    end
  end
end
