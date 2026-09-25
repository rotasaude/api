# "Cheguei na unidade" de um horário (spec 2026-09-25 §4): só no dia.
module Citizens
  class IssueAppointmentCheckInCode
    def self.call(citizen:, appointment:)
      state = Attendances::AppointmentCheckInEligibility.check(appointment)
      return Result.fail(state) unless state == :ok

      IssueCounterCode.call(citizen: citizen, purpose: "check_in", appointment: appointment)
    end
  end
end
