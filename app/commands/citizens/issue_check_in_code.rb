# "Cheguei na unidade" (spec 2026-09-24-citizen-attendance-check-in §4).
module Citizens
  class IssueCheckInCode
    def self.call(citizen:, triage:)
      state = Attendances::CheckInEligibility.check(triage)
      return Result.fail(state) unless state == :ok

      IssueCounterCode.call(citizen: citizen, purpose: "check_in", triage: triage)
    end
  end
end
