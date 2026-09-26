# O cidadão confirma até o prazo (spec 2026-09-25 §2.6). Confirmar de novo é ok.
module Appointments
  class Confirm
    def self.call(appointment:, now: Time.current)
      ApplicationRecord.transaction do
        appointment.lock!
        next Result.fail(:appointment_ended) if appointment.ended?
        next Result.ok(appointment: appointment) if appointment.status == "confirmed"
        next Result.fail(:confirmation_closed) if now >= appointment.confirmation_deadline_at

        appointment.update!(status: "confirmed", confirmed_at: now)
        DomainEvents.publish("appointment.confirmed", appointment_id: appointment.id)
        Result.ok(appointment: appointment)
      end
    end
  end
end
