# Marcação pela recepção da unidade de destino (spec 2026-09-25 §2.4, §2.7):
# futuro e até 180 dias; com menos de 48h nasce confirmado, senão exige
# confirmação até 24h antes.
# Módulo 17 (ADR 0029): este é o caminho "legacy" — só em dia sem turno.
#
# Conflito de horário (api#26): o horário não tem profissional nem duração,
# então "mesmo horário" é mesma unidade e mesmo início entre os horários vivos
# (marcado ou confirmado). A recepção recebe slot_taken e pode marcar mesmo
# assim (allow_overlap) para um encaixe consciente; o evento registra fit_in.
# A trava por unidade + início serializa duas recepções marcando ao mesmo
# tempo: a segunda só conta depois do COMMIT da primeira.
#
# Travas na ordem de Book/FitIn (Placement.lock!: unidade FOR SHARE → cidadão →
# horários vivos → pedido) e só então a trava do horário: unidade primeiro é a
# ordem do esvaziamento (Drain), que também pega a trava do horário depois.
# O cidadão não pode ter outro horário ativo sobreposto (ADR 0029): o livre
# ocupa Appointment::LEGACY_SPAN; allow_overlap não libera isso (citizen_busy).
module Appointments
  class Schedule
    def self.call(request:, scheduled_at:, health_unit_id:, by:, allow_overlap: false, now: Time.current)
      at = parse(scheduled_at)
      return Result.fail(:invalid_time) if at.nil? || at <= now || at > now + Appointment::MAX_AHEAD
      return Result.fail(:wrong_unit) unless request.target_unit_id == health_unit_id.to_s
      return Result.fail(:invalid_unit) unless request.target_unit.active?

      ApplicationRecord.transaction do
        Placement.lock!(request)
        next Result.fail(:request_not_open) unless request.status == "open"
        # Transição (ADR 0029): a marcação livre só vale em dia sem turno da unidade.
        next Result.fail(:use_slots) if Scheduling::Transition.slots_day?(request.target_unit_id, at.to_date)

        lock_slot!(request.target_unit_id, at)
        next Result.fail(:citizen_busy) if Placement.citizen_busy?(request, at, at + Appointment::LEGACY_SPAN)

        taken = Appointment.where(health_unit_id: request.target_unit_id, scheduled_at: at,
                                  status: Appointment::LIVE).count
        next Result.fail(:slot_taken, details: { taken: taken }) if taken.positive? && !allow_overlap

        appointment = Placement.create!(request: request, at: at, by: by, now: now)
        DomainEvents.publish("appointment.scheduled", appointment_id: appointment.id,
                                                      appointment_request_id: request.id,
                                                      health_unit_id: appointment.health_unit_id,
                                                      born_confirmed: appointment.status == "confirmed",
                                                      fit_in: taken.positive?)
        Result.ok(appointment: appointment)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end

    # pg_advisory_xact_lock devolve void: execute, nunca select_value.
    def self.lock_slot!(health_unit_id, at)
      key = ApplicationRecord.connection.quote("appointment_slot:#{health_unit_id}:#{at.utc.iso8601}")
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{key}))")
    end

    def self.parse(value) = Placement.parse(value)
  end
end
