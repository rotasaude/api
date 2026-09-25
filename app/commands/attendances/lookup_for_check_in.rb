# Confere CPF + código de check-in antes de perguntar a unidade (spec
# 2026-09-24-citizen-attendance-check-in §2.1). Não consome o código.
module Attendances
  class LookupForCheckIn
    def self.call(cpf:, code:, health_unit_id: nil)
      match = Citizens::VerificationCodeMatch.call(cpf: cpf, code: code, purpose: "check_in")
      return match if match.failure?

      appointment = match.payload[:appointment]
      if appointment
        state = AppointmentCheckInEligibility.check(appointment, health_unit_id: health_unit_id)
        return AppointmentCheckInEligibility.failure_for(state, appointment) unless state == :ok

        return Result.ok(citizen: match.payload[:citizen], triage: nil, appointment: appointment)
      end

      triage = match.payload[:triage]
      state = CheckInEligibility.check(triage)
      return failure_for(state, triage) unless state == :ok

      Result.ok(citizen: match.payload[:citizen], triage: triage, appointment: nil)
    end

    def self.failure_for(state, triage)
      return Result.fail(state) unless state == :already_checked_in

      a = triage.attendance
      Result.fail(:already_checked_in, details: { unit_name: a.health_unit.name, checked_in_at: a.checked_in_at })
    end
  end
end
