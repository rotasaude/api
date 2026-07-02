# Camada de prioridade independente do modo de scoring (ADR-0017). Escala-só:
# devolve a MENOR priority entre as regras cujo `when` casa, ou nil. Módulo puro
# e TOTAL — nunca levanta: `rules` não-Array ou elemento não-Hash é ignorado;
# uma regra sem priority inteira >= 1 é descartada (nunca escala para 0). (F-03.6)
module Protocols
  module PriorityRules
    module_function

    def override_for(rules, answers)
      return nil unless rules.is_a?(Array)

      rules
        .select { |rule| rule.is_a?(Hash) && Condition.eval(rule["when"] || rule[:when], answers) }
        .filter_map { |rule| valid_priority(rule) }
        .min
    end

    # nil se priority ausente/não-inteira/< 1 (a regra é ignorada — nunca escala a 0).
    def valid_priority(rule)
      value = Integer(rule["priority"] || rule[:priority], exception: false)
      value if value && value >= 1
    end
  end
end
