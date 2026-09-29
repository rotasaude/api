# Atendimento encerrado com desfecho na lista (e na unidade, se dada),
# encerrado no período.
module Campaigns
  module Criteria
    class AttendanceOutcome
      def self.relation(params)
        scope = Attendance.where(status: "closed", outcome: params.fetch("outcomes"), closed_at: Criteria.period(params))
        scope = scope.where(health_unit_id: params["health_unit_id"]) if params["health_unit_id"]
        scope.select(:citizen_id)
      end
    end
  end
end
