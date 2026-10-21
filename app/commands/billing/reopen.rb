# Reabertura (spec §5.5; contrato §5 com B8): motivo 10..500 (cifrado), só a
# competência fechada; o arquivo anterior fica no histórico e o próximo
# fechamento é a versão seguinte. O step-up é do controlador.
module Billing
  module Reopen
    module_function

    def call(period:, reason:, by:, now: Time.current)
      text = reason.is_a?(String) ? reason.strip : ""
      return Result.fail(:reason_required) unless text.length.between?(10, 500)

      ApplicationRecord.transaction do
        period.lock!
        next Result.fail(:invalid_transition, details: { status: period.status }) unless period.closed?

        period.update!(status: "open", reopened_reason: text, reopened_at: now, reopened_by_user: by)
        DomainEvents.publish("billing_period.reopened", billing_period_id: period.id, version: period.version)
        Result.ok(period: period)
      end
    end
  end
end
