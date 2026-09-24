# Quais triagens podem receber check-in (spec §2.3): web, concluídas há 3 dias
# ou menos e ainda sem atendimento.
module Attendances
  module CheckInEligibility
    WINDOW = 3.days

    module_function

    def check(triage)
      return :triage_not_eligible unless triage.status_completed? && triage.conversation.channel_web?
      return :already_checked_in if Attendance.exists?(triage_id: triage.id)
      return :triage_too_old if triage.completed_at.nil? || triage.completed_at < WINDOW.ago

      :ok
    end

    def eligible_for(citizens)
      Triage.joins(:conversation)
            .where(conversations: { channel: "web", citizen_id: citizens.select(:id) })
            .where(status: "completed").where("triages.completed_at >= ?", WINDOW.ago)
            .where.not(id: Attendance.select(:triage_id))
            .order(completed_at: :desc)
    end
  end
end
