# Triagem concluída com a faixa na lista, concluída no período. `tier` é texto
# do protocolo: renomear a faixa num protocolo novo separa as triagens.
module Campaigns
  module Criteria
    class TriageTier
      def self.relation(params)
        Criteria.triage_citizens(Triage.where(status: "completed", tier: params.fetch("tiers"),
                                              completed_at: Criteria.period(params)))
      end
    end
  end
end
