module Analytics
  module Consolidate
    # Qualidade operacional (spec §3.4): desfechos por unidade, espera em
    # faixas (D11: faixas somam entre dias e recortes; mediana não) e fim dos
    # horários. Faixas: desvio 12 do plano.
    class Quality < Base
      WAIT = "a.called_at - a.checked_in_at"

      def call
        attendances_closed
        attendances_wait
        appointments_ended
      end

      private

      def attendances_closed
        insert!(<<~SQL)
          SELECT #{day('a.closed_at')}, 'attendance.closed', a.health_unit_id, NULL, NULL, NULL,
                 NULL, NULL, a.outcome, COUNT(*), :at
          FROM attendances a
          WHERE a.status = 'closed' AND #{window('a.closed_at')}
          GROUP BY 1, 3, 9
        SQL
      end

      def attendances_wait
        insert!(<<~SQL)
          SELECT #{day('a.called_at')}, 'attendance.wait', a.health_unit_id, NULL, NULL, NULL, NULL, NULL,
                 CASE WHEN #{WAIT} < interval '15 minutes' THEN '0-15'
                      WHEN #{WAIT} < interval '30 minutes' THEN '15-30'
                      WHEN #{WAIT} < interval '60 minutes' THEN '30-60'
                      WHEN #{WAIT} < interval '120 minutes' THEN '60-120'
                      ELSE '120+' END,
                 COUNT(*), :at
          FROM attendances a
          WHERE a.called_at IS NOT NULL AND #{window('a.called_at')}
          GROUP BY 1, 3, 9
        SQL
      end

      def appointments_ended
        insert!(<<~SQL)
          SELECT #{day('ap.ended_at')}, 'appointment.ended', ap.health_unit_id, NULL, NULL, NULL,
                 NULL, NULL, ap.status, COUNT(*), :at
          FROM appointments ap
          WHERE ap.ended_at IS NOT NULL
            AND ap.status IN ('checked_in', 'no_show', 'expired', 'cancelled_by_citizen')
            AND #{window('ap.ended_at')}
          GROUP BY 1, 3, 9
        SQL
      end
    end
  end
end
