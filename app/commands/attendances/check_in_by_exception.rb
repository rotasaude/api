# Check-in sem código (spec §2.1): motivo obrigatório; não valida o cadastro.
module Attendances
  class CheckInByException
    MIN_REASON = 10

    def self.call(cpf:, triage_id:, health_unit_id:, reason:, by:)
      digits = CitizenIdentity::Cpf.normalize(cpf)
      return Result.fail(:invalid_cpf) unless digits
      return Result.fail(:reason_too_short) if reason.to_s.strip.length < MIN_REASON

      unit = HealthUnit.active_units.find_by(id: health_unit_id)
      return Result.fail(:invalid_unit) unless unit

      triage = CheckInEligibility.eligible_for(Citizen.where(cpf: digits)).find_by(id: triage_id)
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
    end
  end
end
