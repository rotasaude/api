# Check-in por código (spec §2.1, §2.6): confere e consome o código sob lock;
# se o par é declarado e o documento foi conferido, valida junto — tudo na
# mesma transação.
module Attendances
  class CheckIn
    def self.call(cpf:, code:, health_unit_id:, document_checked:, by:)
      unit = HealthUnit.active_units.find_by(id: health_unit_id)
      return Result.fail(:invalid_unit) unless unit

      result = nil
      ApplicationRecord.transaction do
        match = Citizens::VerificationCodeMatch.call(cpf: cpf, code: code, lock: true, purpose: "check_in")
        next result = match if match.failure?

        citizen = match.payload[:citizen]
        triage = match.payload[:triage]
        state = CheckInEligibility.check(triage)
        next result = LookupForCheckIn.failure_for(state, triage) unless state == :ok

        match.payload[:verification_code].update!(consumed_at: Time.current)
        verified = false
        if document_checked == true && citizen.active_verification.nil?
          Citizens::Verify.record!(citizen: citizen, by: by)
          verified = true
        end
        attendance = Attendance.create!(triage: triage, citizen: citizen, health_unit: unit, checked_in_by_user: by,
                                        checked_in_at: Time.current, check_in_method: "code")
        publish(attendance)
        result = Result.ok(attendance: attendance, verified: verified)
      end
      result
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:already_checked_in)
    end

    def self.publish(attendance)
      DomainEvents.publish("attendance.checked_in",
                           attendance_id: attendance.id, triage_id: attendance.triage_id,
                           citizen_id: attendance.citizen_id, health_unit_id: attendance.health_unit_id,
                           checked_in_by_user_id: attendance.checked_in_by_user_id,
                           check_in_method: attendance.check_in_method)
    end
  end
end
