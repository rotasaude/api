# app/services/analytics/consolidate/base.rb
module Analytics
  module Consolidate
    # Cada métrica é um INSERT ... SELECT ... GROUP BY sobre o cru da janela
    # (dias no fuso da cidade), direto no SQL: nenhuma linha de pessoa passa
    # pelo Ruby, e só a contagem sai de cada grupo.
    class Base
      COLUMNS = "day, metric, health_unit_id, neighborhood_id, protocol_name, protocol_version, tier, " \
                "question_id, dim, value, consolidated_at"

      # Triagens com a versão do protocolo (`pd`) e a marca de consentimento
      # revogado já calculada numa coluna (`t.consent_revoked`): assim os CASE
      # que agrupam por ela não carregam subconsulta correlacionada no GROUP BY.
      # O filtro de janela aplicado em `t` desce para dentro da subconsulta.
      TRIAGES = <<~SQL.squish
        FROM (
          SELECT tr.*, EXISTS (SELECT 1 FROM consents c
                               WHERE c.conversation_id = tr.conversation_id AND c.revoked_at IS NOT NULL) AS consent_revoked
          FROM triages tr
        ) t
        JOIN protocol_definitions pd ON pd.id = t.protocol_definition_id
      SQL
      # Triagem revogada (desvio 1 do plano): abortada por revogação, ou com o
      # consentimento da PRÓPRIA conversa revogado — o wpda revoga depois de
      # concluir, e a triagem segue completed. Sobre o alias `t` de TRIAGES.
      REVOKED = "t.consent_revoked"
      REVOCATION = "(t.status = 'aborted_by_revocation' OR t.consent_revoked)"

      def self.call(from:, to:, at:) = new(from: from, to: to, at: at).call

      def initialize(from:, to:, at:)
        @binds = { lower: from.in_time_zone.utc, upper: (to + 1).in_time_zone.utc, at: at, tz: Analytics::TZ }
      end

      private

      def insert!(select_sql)
        ApplicationRecord.connection.execute(
          ApplicationRecord.sanitize_sql_array([ "INSERT INTO analytics_daily_facts (#{COLUMNS}) #{select_sql}", @binds ])
        )
      end

      # As colunas datetime são `timestamp without time zone` em UTC: rotula
      # como UTC e só então leva ao relógio local (mesma lição de
      # Admin::Api::Period#group_expr).
      def day(column) = "((#{column} AT TIME ZONE 'UTC') AT TIME ZONE :tz)::date"

      def window(column) = "#{column} >= :lower AND #{column} < :upper"
    end
  end
end
