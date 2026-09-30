# app/services/analytics/consolidate/demand.rb
module Analytics
  module Consolidate
    # Demanda por território (spec §3.4): triagens por bairro, protocolo e
    # versão (e tier na concluída), chegadas por unidade e pedidos pela
    # unidade-alvo. Atendimento não tem bairro: o território é o da triagem.
    class Demand < Base
      # Triagem revogada perde o território no Analytics (desvio 1).
      TERRITORY = "CASE WHEN #{REVOCATION} THEN NULL ELSE t.neighborhood_id END"

      def call
        triages_started
        triages_completed
        triages_aborted
        attendances_checked_in
        requests_opened
        requests_closed
      end

      private

      def triages_started
        insert!(<<~SQL)
          SELECT #{day('t.created_at')}, 'triage.started', NULL, #{TERRITORY}, t.protocol_name, pd.version,
                 NULL, NULL, '', COUNT(*), :at
          #{TRIAGES}
          WHERE #{window('t.created_at')}
          GROUP BY 1, 4, 5, 6
        SQL
      end

      def triages_completed
        insert!(<<~SQL)
          SELECT #{day('t.completed_at')}, 'triage.completed', NULL, t.neighborhood_id, t.protocol_name, pd.version,
                 t.tier, NULL, '', COUNT(*), :at
          #{TRIAGES}
          WHERE t.status = 'completed' AND NOT #{REVOKED} AND #{window('t.completed_at')}
          GROUP BY 1, 4, 5, 6, 7
        SQL
      end

      def triages_aborted
        insert!(<<~SQL)
          SELECT #{day('t.created_at')}, 'triage.aborted', NULL, #{TERRITORY}, t.protocol_name, pd.version,
                 NULL, NULL,
                 CASE WHEN #{REVOCATION} THEN 'revocation'
                      WHEN t.status = 'aborted_by_timeout' THEN 'timeout'
                      ELSE 'cancellation' END,
                 COUNT(*), :at
          #{TRIAGES}
          WHERE (t.status IN ('aborted_by_timeout', 'aborted_by_cancellation', 'aborted_by_revocation')
                 OR (t.status = 'completed' AND #{REVOKED}))
            AND #{window('t.created_at')}
          GROUP BY 1, 4, 5, 6, 9
        SQL
      end

      def attendances_checked_in
        insert!(<<~SQL)
          SELECT #{day('a.checked_in_at')}, 'attendance.checked_in', a.health_unit_id, NULL, NULL, NULL,
                 NULL, NULL, a.check_in_method, COUNT(*), :at
          FROM attendances a
          WHERE #{window('a.checked_in_at')}
          GROUP BY 1, 3, 9
        SQL
      end

      def requests_opened
        insert!(<<~SQL)
          SELECT #{day('r.created_at')}, 'request.opened', r.target_unit_id, NULL, NULL, NULL,
                 NULL, NULL, r.kind, COUNT(*), :at
          FROM appointment_requests r
          WHERE #{window('r.created_at')}
          GROUP BY 1, 3, 9
        SQL
      end

      def requests_closed
        insert!(<<~SQL)
          SELECT #{day('r.closed_at')}, 'request.closed', r.target_unit_id, NULL, NULL, NULL,
                 NULL, NULL, r.closed_reason, COUNT(*), :at
          FROM appointment_requests r
          WHERE r.closed_at IS NOT NULL AND #{window('r.closed_at')}
          GROUP BY 1, 3, 9
        SQL
      end
    end
  end
end
