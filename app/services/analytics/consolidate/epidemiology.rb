# app/services/analytics/consolidate/epidemiology.rb
module Analytics
  module Consolidate
    # Epidemiologia (spec §3.4, D5): respostas das perguntas que a VERSÃO da
    # triagem marca `analytic`, só boolean/enum, e só a resposta que bate com
    # uma opção declarada. Pergunta sem marca, integer, text e resposta fora da
    # lista nunca viram agregado — mesmo numa definição gravada direto no
    # banco, sem passar pelo schema. Definição malformada (steps que não é
    # array, null nas opções) é ignorada: uma linha ruim não pode abortar a
    # transação das quatro frentes da cidade.
    class Epidemiology < Base
      ANSWER = "t.answers ->> (s.step ->> 'id')"

      def call
        insert!(<<~SQL)
          SELECT #{day('t.completed_at')}, 'epi.answer', NULL, t.neighborhood_id, t.protocol_name, pd.version,
                 NULL, s.step ->> 'id', #{ANSWER}, COUNT(*), :at
          #{TRIAGES}
          CROSS JOIN LATERAL jsonb_array_elements(
            CASE WHEN jsonb_typeof(pd.definition -> 'steps') = 'array' THEN pd.definition -> 'steps' ELSE '[]'::jsonb END
          ) AS s(step)
          WHERE t.status = 'completed' AND NOT #{REVOKED} AND #{window('t.completed_at')}
            AND s.step -> 'analytic' = 'true'::jsonb
            AND #{ANSWER} IS NOT NULL
            AND (
              (s.step ->> 'answer_type' = 'boolean' AND #{ANSWER} IN ('true', 'false'))
              OR (s.step ->> 'answer_type' = 'enum' AND jsonb_typeof(s.step -> 'options') = 'array'
                  AND (s.step -> 'options') @> jsonb_build_array(#{ANSWER}))
            )
          GROUP BY 1, 4, 5, 6, 8, 9
        SQL
      end
    end
  end
end
