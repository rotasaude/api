# Camada de prioridade independente do modo de scoring (ADR-0009). Escala-só:
# devolve a MENOR priority entre as regras cujo `when` casa, ou nil. Módulo puro
# e TOTAL — nunca levanta: `rules` não-Array ou elemento não-Hash é ignorado;
# uma regra sem priority inteira >= 1 é descartada (nunca escala para 0). (F-03.6)
module Protocols
  module PriorityRules
    module_function

    def override_for(rules, answers)
      match_for(rules, answers)&.last
    end

    # [índice da regra, priority] da regra que escala mais (menor priority;
    # empate fica com a primeira), ou nil. O índice alimenta o trail (F-03.7).
    def match_for(rules, answers)
      return nil unless rules.is_a?(Array)

      rules.each_with_index
        .select { |rule, _| rule.is_a?(Hash) && Condition.eval(rule["when"] || rule[:when], answers) }
        .filter_map { |rule, index| (priority = valid_priority(rule)) && [index, priority] }
        .min_by { |index, priority| [priority, index] }
    end

    # nil se priority ausente/não-inteira/< 1 (a regra é ignorada — nunca escala a 0).
    def valid_priority(rule)
      value = Integer(rule["priority"] || rule[:priority], exception: false)
      value if value && value >= 1
    end
  end
end
