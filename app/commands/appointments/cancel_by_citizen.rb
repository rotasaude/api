# Cancelamento pelo cidadão, com motivo (spec 2026-09-25 §2.5, §2.8): encerra o pedido.
module Appointments
  class CancelByCitizen
    MIN_REASON = 10

    def self.call(appointment:, reason:)
      return Result.fail(:reason_too_short) if reason.to_s.strip.length < MIN_REASON

      ApplicationRecord.transaction do
        appointment.lock!
        next Result.fail(:appointment_ended) if appointment.ended?

        appointment.update!(status: "cancelled_by_citizen", cancel_reason: reason.to_s.strip, ended_at: Time.current)
        AppointmentRequests::Lifecycle.close!(appointment.request, reason: "citizen_cancelled")
        DomainEvents.publish("appointment.cancelled", appointment_id: appointment.id, by: "citizen")
        Result.ok(appointment: appointment)
      end
    end
  end
end
