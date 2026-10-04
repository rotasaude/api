# Esvaziar unidade (api#29; F-09.3; ADR 0018/0019, Revisão 2026-10-04). O
# municipal_admin move, de uma vez, todos os pedidos abertos e horários
# marcados da unidade para outra unidade ativa, com um motivo (texto imutável).
#
# A unidade do pedido e a do horário não mudam (triggers): mover encerra o
# pedido antigo como `moved` e cria outro igual na unidade de destino, ligado
# por moved_from_request_id e com o mesmo created_at (mantém o lugar na fila e
# não conta como demanda nova); o horário vivo vai junto, com a mesma data e
# hora, num horário novo ligado por moved_from_appointment_id. Com 48h ou mais
# até o horário, ele pede nova confirmação (prazo 24h antes, lembrete F-08.7 e
# expiração F-08.5); com menos, nasce confirmado. Horário ocupado no destino
# vai como encaixe (fit_in no evento, api#26), sob a mesma trava de horário da
# marcação. Horário já vencido (prazo passado ou falta) segue o caminho normal
# antes (Lapse) e o pedido reaberto é movido como pedido aberto.
#
# Travas, na ordem que evita deadlock: as duas unidades em ordem de id (FOR
# UPDATE na que esvazia, FOR SHARE no destino), depois os horários e só então
# os pedidos — a mesma ordem de Cancel e Lapse (horário, depois pedido).
# Reasons: :invalid_target, :reason_too_short.
module HealthUnits
  class Drain
    MIN_REASON = 10
    UUID = /\A\h{8}-(\h{4}-){3}\h{12}\z/

    def self.call(unit:, target_unit_id:, reason:, by:, now: Time.current)
      reason = reason.to_s.strip
      target = HealthUnit.find_by(id: target_unit_id.to_s) if target_unit_id.to_s.match?(UUID)
      return Result.fail(:invalid_target) if target.nil? || !target.active? || target.id == unit.id
      return Result.fail(:reason_too_short) if reason.length < MIN_REASON

      ApplicationRecord.transaction do
        lock_units(unit, target)
        appointments = Appointment.live.where(health_unit_id: unit.id).order(:id).lock.to_a
        appointments.each { |a| lapse_if_due(a, now) }
        requests = AppointmentRequest.live_requests.where(target_unit_id: unit.id).order(:id).lock.to_a
        moved_appointments = requests.sum { |request| move(request, target, now) }
        drain = HealthUnitDrain.create!(health_unit: unit, target_unit: target, reason: reason, drained_by_user: by,
                                        requests_count: requests.size, appointments_count: moved_appointments,
                                        created_at: now)
        DomainEvents.publish("health_unit.drained", health_unit_drain_id: drain.id, health_unit_id: unit.id,
                                                    target_unit_id: target.id, requests_count: requests.size,
                                                    appointments_count: moved_appointments)
        Result.ok(drain: drain, requests: requests.size, appointments: moved_appointments)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_target)
    end

    def self.lock_units(unit, target)
      [ unit, target ].sort_by(&:id).each do |u|
        u.id == unit.id ? unit.lock! : HealthUnit.lock_active!(target.id)
      end
    end

    def self.lapse_if_due(appointment, now)
      to = appointment.status == "scheduled" ? "expired" : "no_show"
      Appointments::Lapse.call(appointment: appointment, to: to, now: now) if Appointments::Lapse.due?(appointment, to, now)
    end

    # Devolve 1 se levou um horário vivo junto, 0 se não.
    def self.move(request, target, now)
      live = request.appointments.live.first
      live&.update!(status: "moved", ended_at: now)
      AppointmentRequests::Lifecycle.close!(request, reason: "moved")

      fresh = AppointmentRequest.create!(
        origin_attendance_id: request.origin_attendance_id, citizen_id: request.citizen_id,
        root_triage_id: request.root_triage_id, origin_unit_id: request.origin_unit_id, target_unit: target,
        kind: request.kind, note: request.note, reopened_reason: request.reopened_reason,
        moved_from_request: request, status: live ? "scheduled" : "open", created_at: request.created_at
      )
      DomainEvents.publish("appointment_request.moved", from_request_id: request.id, to_request_id: fresh.id,
                                                        from_unit_id: request.target_unit_id, to_unit_id: target.id)
      return 0 unless live

      move_appointment(live, fresh, target, now)
      1
    end

    def self.move_appointment(old, request, target, now)
      Appointments::Schedule.lock_slot!(target.id, old.scheduled_at)
      fit_in = Appointment.where(health_unit_id: target.id, scheduled_at: old.scheduled_at,
                                 status: Appointment::LIVE).exists?
      born_confirmed = old.scheduled_at - now < Appointment::BORN_CONFIRMED_WITHIN
      fresh = Appointment.create!(
        request: request, citizen_id: old.citizen_id, health_unit: target, scheduled_at: old.scheduled_at,
        scheduled_by_user_id: old.scheduled_by_user_id, moved_from_appointment: old,
        status: born_confirmed ? "confirmed" : "scheduled", confirmed_at: born_confirmed ? now : nil,
        confirmation_deadline_at: born_confirmed ? nil : old.scheduled_at - Appointment::CONFIRMATION_LEAD
      )
      DomainEvents.publish("appointment.moved", from_appointment_id: old.id, to_appointment_id: fresh.id,
                                                to_unit_id: target.id, born_confirmed: born_confirmed, fit_in: fit_in)
    end
    private_class_method :lock_units, :lapse_if_due, :move, :move_appointment
  end
end
