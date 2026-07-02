# Camada de prioridade independente do modo de scoring (ADR-0017). Escala-só:
# devolve a MENOR priority entre as regras cujo `when` casa (via Condition,
# total), ou nil se nenhuma casa. Módulo puro. (F-03.6)
module Protocols
  module PriorityRules
    module_function

    def override_for(rules, answers)
      Array(rules)
        .select { |rule| Condition.eval(rule["when"] || rule[:when], answers) }
        .map { |rule| (rule["priority"] || rule[:priority]).to_i }
        .min
    end
  end
end
