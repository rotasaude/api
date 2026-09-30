module Analytics
  module Consolidate
    # Calibração de protocolo (spec §3.4): versão × tier × desfecho do
    # atendimento da própria triagem (desvio 2 do plano). Por versão porque
    # `tier` é texto de cada protocolo (D13): renomear a faixa separa as séries.
    # Desfecho que chega depois de 30 dias não entra (D10).
    class Calibration < Base
      def call
        insert!(<<~SQL)
          SELECT #{day('t.completed_at')}, 'calibration.outcome', NULL, NULL, t.protocol_name, pd.version,
                 t.tier, NULL, COALESCE(a.outcome, 'none'), COUNT(*), :at
          #{TRIAGES}
          LEFT JOIN attendances a ON a.triage_id = t.id AND a.status = 'closed'
          WHERE t.status = 'completed' AND NOT #{REVOKED} AND #{window('t.completed_at')}
          GROUP BY 1, 5, 6, 7, 9
        SQL
      end
    end
  end
end
