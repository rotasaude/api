# A recepção decide não remarcar (spec 2026-09-25 §2.8): justificativa 10+.
module AppointmentRequests
  class Dismiss
    MIN_REASON = 10

    def self.call(request:, reason:, health_unit_id:, by:)
      return Result.fail(:wrong_unit) unless request.target_unit_id == health_unit_id.to_s

      ApplicationRecord.transaction do
        request.lock!
        next Result.fail(:request_not_open) unless request.status == "open"
        next Result.fail(:reason_too_short) if reason.to_s.strip.length < MIN_REASON

        Lifecycle.close!(request, reason: "dismissed", by: by, dismiss_reason: reason.to_s.strip)
        Result.ok(request: request)
      end
    end
  end
end
