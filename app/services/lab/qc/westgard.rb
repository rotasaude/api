# Regras de Westgard sobre z-scores (spec §5.3; Desvio 5; C-E14). Função pura:
# quem chama monta a série (mesmo lote, nível, analito e aparelho, corridas
# não reprovadas, mais antigo primeiro), os pares (outros níveis do mesmo
# analito na mesma corrida) e a série entre níveis (C-E14/C-E15: o analito
# no aparelho, todos os níveis do MESMO lote de controle — troca de lote
# reinicia —, corridas não reprovadas, em ordem cronológica, sem o valor
# atual). 2-2s e R-4s olham os pares; 4-1s e 10x olham a série do nível E a
# série entre níveis. 1-2s é aviso; o resto reprova. Limites estritos. Só BigDecimal.
module Lab
  module Qc
    module Westgard
      RULES = LabQcRule::RULES
      REJECT = %w[1_3s 2_2s R_4s 4_1s 10x].freeze
      ONE = BigDecimal("1")
      TWO = BigDecimal("2")
      THREE = BigDecimal("3")
      Evaluation = Data.define(:rules_fired, :outcome)

      module_function

      def evaluate(z:, series:, peers:, cross: [], enabled: RULES)
        raise ArgumentError, "Westgard takes BigDecimal only" unless [ z, *series, *peers, *cross ].all?(BigDecimal)

        checks = {
          "1_2s" => -> { z.abs > TWO },
          "1_3s" => -> { z.abs > THREE },
          "2_2s" => -> { same_side?(z, series.last, TWO) || peers.any? { |p| same_side?(z, p, TWO) } },
          "R_4s" => -> { peers.any? { |p| (z > TWO && p < -TWO) || (z < -TWO && p > TWO) } },
          "4_1s" => -> { streak?([ *series.last(3), z ], 4, ONE) || streak?([ *cross.last(3), z ], 4, ONE) },
          "10x" => -> { streak?([ *series.last(9), z ], 10, 0) || streak?([ *cross.last(9), z ], 10, 0) }
        }
        fired = RULES.select { |rule| enabled.include?(rule) && checks.fetch(rule).call }
        outcome = if fired.intersect?(REJECT) then "reject"
        elsif fired.include?("1_2s") then "warning"
        else "ok"
        end
        Evaluation.new(rules_fired: fired, outcome: outcome)
      end

      def same_side?(a, b, limit) = !b.nil? && ((a > limit && b > limit) || (a < -limit && b < -limit))
      def streak?(values, size, limit) = values.size == size && (values.all? { |v| v > limit } || values.all? { |v| v < -limit })
      private_class_method :same_side?, :streak?
    end
  end
end
