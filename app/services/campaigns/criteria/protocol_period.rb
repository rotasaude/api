# Triagem concluída com esse protocolo, concluída no período.
module Campaigns
  module Criteria
    class ProtocolPeriod
      def self.relation(params)
        Criteria.triage_citizens(Triage.where(status: "completed", protocol_name: params.fetch("protocol_name"),
                                              completed_at: Criteria.period(params)))
      end
    end
  end
end
