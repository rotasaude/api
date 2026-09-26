# Horário que venceu sem ação (spec 2026-09-25 §5): expired (sem
# confirmação no prazo) ou no_show (confirmado, dia terminou). Sob lock e
# conferindo de novo: se o cidadão agiu antes, não faz nada.
module Appointments
  class Lapse
    FROM = { "expired" => "scheduled", "no_show" => "confirmed" }.freeze

    def self.call(appointment:, to:, now: Time.current)
      ApplicationRecord.transaction do
        appointment.lock!
        next Result.ok(appointment: appointment, skipped: true) unless due?(appointment, to, now)

        appointment.update!(status: to, ended_at: now)
        AppointmentRequests::Lifecycle.reopen!(appointment.request, reason: to)
        DomainEvents.publish("appointment.#{to}", appointment_id: appointment.id,
                                                  appointment_request_id: appointment.request_id)
        Result.ok(appointment: appointment)
      end
    end

    def self.due?(appointment, to, now)
      return false unless appointment.status == FROM.fetch(to)

      if to == "expired"
        appointment.confirmation_deadline_at <= now
      else
        appointment.scheduled_at < now.in_time_zone.beginning_of_day
      end
    end
  end
end
