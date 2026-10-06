# Marcação em vaga (ADR 0029 §4.3): a vaga tem de existir no cálculo
# (Scheduling::Availability) para o profissional, o início e o tipo; o cidadão
# não pode ter outro horário ativo sobreposto; a EXCLUDE do banco decide a
# corrida entre duas recepções (slot_taken). Em pedido já marcado, remarca.
module Appointments
  module Book
    module_function

    def call(request:, professional:, starts_at:, type:, by:, now: Time.current)
      at = Placement.parse(starts_at)
      return Result.fail(:invalid_time) if at.nil? || at <= now || at > now + Appointment::MAX_AHEAD
      return Result.fail(:slot_unavailable) if professional.nil?
      return Result.fail(:type_not_served) if type.nil?
      return Result.fail(:wrong_unit) if request.target_unit_id.nil?

      ApplicationRecord.transaction do
        Placement.lock!(request)
        next Result.fail(:request_not_open) unless Placement.bookable?(request)

        HealthUnit.lock_active!(request.target_unit_id)
        slot = find_slot(request, professional, type, at, now)
        next Result.fail(served?(request, professional, type) ? :slot_unavailable : :type_not_served) unless slot
        next Result.fail(:citizen_busy) if Placement.citizen_busy?(request, at, slot.ends_at)

        appointment = Placement.create!(request: request, at: at, by: by, now: now, booking_kind: "slot",
                                        professional_id: professional.id, appointment_type_key: type.key,
                                        ends_at: slot.ends_at, shift_id: slot.shift_id)
        DomainEvents.publish("appointment.booked", appointment_id: appointment.id, request_id: request.id,
                                                   booking_kind: "slot")
        Result.ok(appointment: appointment)
      end
    rescue ActiveRecord::ExclusionViolation
      Result.fail(:slot_taken)
    rescue HealthUnit::Inactive
      Result.fail(:invalid_unit)
    end

    def find_slot(request, professional, type, at, now)
      day = at.to_date
      Scheduling::Availability.for(unit: request.target_unit, from: day, to: day, appointment_type: type, now: now)
                              .find { |s| s.professional_id == professional.id && s.starts_at == at }
    end

    def served?(request, professional, type)
      type.active && ProfessionalLink.active.where(professional_id: professional.id, health_unit_id: request.target_unit_id)
                                     .any? { |link| Scheduling::AppointmentTypes.serves?(type, link.cbo_code) }
    end
  end
end
