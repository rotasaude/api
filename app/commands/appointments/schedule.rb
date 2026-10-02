# Marcação pela recepção da unidade de destino (spec 2026-09-25 §2.4, §2.7):
# futuro e até 180 dias; com menos de 48h nasce confirmado, senão exige
# confirmação até 24h antes.
#
# Conflito de horário (api#26): o horário não tem profissional nem duração,
# então "mesmo horário" é mesma unidade e mesmo início entre os horários vivos
# (marcado ou confirmado). A recepção recebe slot_taken e pode marcar mesmo
# assim (allow_overlap) para um encaixe consciente; o evento registra fit_in.
# A trava por unidade + início serializa duas recepções marcando ao mesmo
# tempo: a segunda só conta depois do COMMIT da primeira.
module Appointments
  class Schedule
    def self.call(request:, scheduled_at:, health_unit_id:, by:, allow_overlap: false, now: Time.current)
      at = parse(scheduled_at)
      return Result.fail(:invalid_time) if at.nil? || at <= now || at > now + Appointment::MAX_AHEAD
      return Result.fail(:wrong_unit) unless request.target_unit_id == health_unit_id.to_s
      return Result.fail(:invalid_unit) unless request.target_unit.active?

      born_confirmed = at - now < Appointment::BORN_CONFIRMED_WITHIN
      ApplicationRecord.transaction do
        request.lock!
        next Result.fail(:request_not_open) unless request.status == "open"

        lock_slot!(request.target_unit_id, at)
        taken = Appointment.where(health_unit_id: request.target_unit_id, scheduled_at: at,
                                  status: Appointment::LIVE).count
        next Result.fail(:slot_taken, details: { taken: taken }) if taken.positive? && !allow_overlap

        appointment = Appointment.create!(
          request: request, citizen: request.citizen, health_unit: request.target_unit, scheduled_at: at,
          scheduled_by_user: by, status: born_confirmed ? "confirmed" : "scheduled",
          confirmed_at: born_confirmed ? now : nil,
          confirmation_deadline_at: born_confirmed ? nil : at - Appointment::CONFIRMATION_LEAD
        )
        request.update!(status: "scheduled", reopened_reason: nil)
        DomainEvents.publish("appointment.scheduled", appointment_id: appointment.id,
                                                      appointment_request_id: request.id,
                                                      health_unit_id: appointment.health_unit_id,
                                                      born_confirmed: born_confirmed,
                                                      fit_in: taken.positive?)
        Result.ok(appointment: appointment)
      end
    end

    # pg_advisory_xact_lock devolve void: execute, nunca select_value.
    def self.lock_slot!(health_unit_id, at)
      key = ApplicationRecord.connection.quote("appointment_slot:#{health_unit_id}:#{at.utc.iso8601}")
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{key}))")
    end

    def self.parse(value)
      Time.zone.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
