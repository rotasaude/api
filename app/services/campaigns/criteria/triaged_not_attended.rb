# Triagem concluída no período sem nenhum atendimento com aquele triage_id.
module Campaigns
  module Criteria
    class TriagedNotAttended
      def self.relation(params)
        attended = Attendance.where.not(triage_id: nil).select(:triage_id)
        Criteria.triage_citizens(Triage.where(status: "completed", completed_at: Criteria.period(params))
                                       .where.not(id: attended))
      end
    end
  end
end
