# Encaixe (ADR 0029 §4.3): horário extra dentro do turno, com justificativa
# (≥ 10 caracteres, imutável, fora de evento e log), contado contra o limite do
# turno sob FOR UPDATE do turno — dois encaixes no último lugar se enfileiram e
# o segundo vê o primeiro. Pode sobrepor vaga ocupada (a EXCLUDE só cobre
# booking_kind 'slot'). Travas: as de Placement.lock! (unidade → cidadão →
# horários vivos → pedido) e, por último, o turno.
module Appointments
  module FitIn
    module_function

    def call(request:, professional:, shift:, starts_at:, type:, reason:, by:, now: Time.current)
      reason = reason.to_s.strip
      return Result.fail(:invalid_reason) if reason.length < Appointment::MIN_FIT_IN_REASON

      at = Placement.parse(starts_at)
      return Result.fail(:invalid_time) if at.nil? || at <= now || at > now + Appointment::MAX_AHEAD
      return Result.fail(:outside_shift) if shift.nil? || professional.nil? || shift.professional_id != professional.id
      return Result.fail(:type_not_served) if type.nil? || !type.active
      return Result.fail(:wrong_unit) if request.target_unit_id.nil?

      ends = at + type.duration_minutes.minutes
      # requires_new: mesma forma do Book — quem chama pode envolver numa transação.
      ApplicationRecord.transaction(requires_new: true) do
        Placement.lock!(request)
        next Result.fail(:request_not_open) unless Placement.bookable?(request)

        shift.lock!
        link = shift.professional_link
        next Result.fail(:outside_shift) if shift.cancelled_at || link.health_unit_id != request.target_unit_id
        next Result.fail(:type_not_served) unless Scheduling::AppointmentTypes.serves?(type, link.cbo_code)
        next Result.fail(:outside_shift) unless at >= shift.starts_at && ends <= shift.ends_at
        if Scheduling::FitInLimit.count(shift, except_request_id: request.id) >= Scheduling::FitInLimit.for(shift)
          next Result.fail(:fit_in_limit)
        end
        next Result.fail(:citizen_busy) if Placement.citizen_busy?(request, at, ends)

        appointment = Placement.create!(request: request, at: at, by: by, now: now, booking_kind: "fit_in",
                                        professional_id: professional.id, appointment_type_key: type.key, ends_at: ends,
                                        shift_id: shift.id, fit_in_reason: reason)
        DomainEvents.publish("appointment.booked", appointment_id: appointment.id, request_id: request.id,
                                                   booking_kind: "fit_in")
        DomainEvents.publish("appointment.fit_in_created", appointment_id: appointment.id, shift_id: shift.id)
        Result.ok(appointment: appointment)
      end
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end
  end
end
