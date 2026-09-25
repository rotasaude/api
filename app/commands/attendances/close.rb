# Desfecho (spec 2026-09-25 §2.1, §2.3): left só de waiting; desfecho
# clínico só de in_care. return e referred com unidade abrem o pedido na
# mesma transação.
module Attendances
  class Close
    def self.call(attendance:, outcome:, referral_unit_id:, referral_note:, by:)
      outcome = outcome.to_s
      return Result.fail(:invalid_outcome) unless Attendance::OUTCOMES.include?(outcome)

      note = referral_note.to_s.strip.presence
      unit = nil
      if outcome == "referred"
        if referral_unit_id.present?
          unit = HealthUnit.active_units.find_by(id: referral_unit_id)
          return Result.fail(:invalid_unit) unless unit
        end
        return Result.fail(:referral_required) if unit.nil? && note.nil?
      end

      ApplicationRecord.transaction do
        attendance.lock!
        next Result.fail(:already_closed) unless attendance.open?
        next Result.fail(:invalid_transition) unless allowed?(attendance.status, outcome)

        attendance.update!(status: "closed", outcome: outcome, closed_by_user: by, closed_at: Time.current,
                           referral_unit: unit, referral_note: (%w[referred return].include?(outcome) ? note : nil))
        request = AppointmentRequests::Lifecycle.open_for!(attendance, outcome: outcome, unit: unit)
        DomainEvents.publish("attendance.closed", attendance_id: attendance.id, outcome: outcome,
                                                  closed_by_user_id: by.id)
        Result.ok(attendance: attendance, appointment_request: request)
      end
    end

    def self.allowed?(status, outcome)
      outcome == "left" ? status == "waiting" : status == "in_care"
    end
  end
end
