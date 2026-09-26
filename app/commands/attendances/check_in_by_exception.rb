# Check-in sem código (spec §2.1): motivo obrigatório; não valida o cadastro.
# Também cobre o check-in de exceção de um horário (spec 2026-09-25 §2.10).
module Attendances
  class CheckInByException
    MIN_REASON = 10

    def self.call(cpf:, health_unit_id:, reason:, by:, triage_id: nil, appointment_id: nil)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits
      return Result.fail(:reason_too_short) if reason.to_s.strip.length < MIN_REASON

      unit = HealthUnit.active_units.find_by(id: health_unit_id)
      return Result.fail(:invalid_unit) unless unit

      citizens = Citizen.where(cpf: digits)

      if appointment_id
        appointment = AppointmentCheckInEligibility.eligible_for(citizens, unit.id).find_by(id: appointment_id)
        return Result.fail(:triage_not_eligible) unless appointment

        attendance = nil
        ApplicationRecord.transaction do
          attendance = Attendance.create!(triage: nil, appointment: appointment, citizen: appointment.citizen,
                                          health_unit: unit, checked_in_by_user: by, checked_in_at: Time.current,
                                          check_in_method: "cpf_exception", exception_reason: reason.to_s.strip)
          CheckIn.fulfil(appointment)
          CheckIn.publish(attendance)
        end
        return Result.ok(attendance: attendance)
      end

      triage = CheckInEligibility.eligible_for(citizens).find_by(id: triage_id)
      return Result.fail(:triage_not_eligible) unless triage

      attendance = nil
      ApplicationRecord.transaction do
        attendance = Attendance.create!(triage: triage, citizen: triage.conversation.citizen, health_unit: unit,
                                        checked_in_by_user: by, checked_in_at: Time.current,
                                        check_in_method: "cpf_exception", exception_reason: reason.to_s.strip)
        CheckIn.publish(attendance)
      end
      Result.ok(attendance: attendance)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:triage_not_eligible)
    rescue CheckIn::AppointmentNotEligible
      Result.fail(:appointment_not_eligible)
    end
  end
end
