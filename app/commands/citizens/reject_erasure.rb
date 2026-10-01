# ADR 0026: o municipal_admin recusa o pedido de exclusão, com motivo (≥ 10
# caracteres depois do strip). Nada se apaga; a recusa é gravada uma vez.
# Reasons: :reason_too_short, :not_pending.
module Citizens
  module RejectErasure
    MIN_REASON = 10

    module_function

    def call(request:, reason:, by:)
      reason = reason.to_s.strip
      return Result.fail(:reason_too_short) if reason.length < MIN_REASON

      result = nil
      ApplicationRecord.transaction do
        request.lock!
        next result = Result.fail(:not_pending) unless request.status == "pending"

        # O banco não exige decided_by_user: quem decide é gravado aqui, sempre.
        request.update!(status: "rejected", decided_by_user: by, decided_at: Time.current, reject_reason: reason)
        DomainEvents.publish("citizen.erasure_rejected", request_id: request.id)
        result = Result.ok(request: request)
      end
      result
    end
  end
end
