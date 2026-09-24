# Desfecho do atendimento (spec §2.4): encerra uma vez, sob lock.
module Attendances
  class Close
    def self.call(attendance:, outcome:, referral_unit_id:, referral_note:, by:)
      return Result.fail(:invalid_outcome) unless Attendance::OUTCOMES.include?(outcome.to_s)

      note = referral_note.to_s.strip.presence
      unit = nil
      if outcome.to_s == "referred"
        if referral_unit_id.present?
          unit = HealthUnit.active_units.find_by(id: referral_unit_id)
          return Result.fail(:invalid_unit) unless unit
        end
        return Result.fail(:referral_required) if unit.nil? && note.nil?
      end

      outcome_result = ApplicationRecord.transaction do
        attendance.lock!
        next :already_closed unless attendance.open?

        attendance.update!(status: "closed", outcome: outcome.to_s, closed_by_user: by, closed_at: Time.current,
                           referral_unit: (outcome.to_s == "referred" ? unit : nil),
                           referral_note: (outcome.to_s == "referred" ? note : nil))
        DomainEvents.publish("attendance.closed", attendance_id: attendance.id, outcome: attendance.outcome,
                                                  closed_by_user_id: by.id)
        :ok
      end
      outcome_result == :ok ? Result.ok(attendance: attendance) : Result.fail(outcome_result)
    end
  end
end
