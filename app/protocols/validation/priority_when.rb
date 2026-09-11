# Valida priority_when no PUBLISH (F-03.6): cada regra tem um `when` válido
# (via Validation::Condition) e priority inteiro em 1..9. Ver ADR-0009.
module Protocols
  module Validation
    module PriorityWhen
      def self.call(definition)
        rules = definition["priority_when"]
        return [] unless rules.is_a?(Array)

        by_id = (definition["steps"] || []).to_h { |s| [s["id"], s] }
        rules.flat_map do |rule|
          errs = Condition.errors(rule["when"] || {}, by_id)
          priority = rule["priority"]
          errs << "priority_when priority must be an integer 1..9" unless priority.is_a?(Integer) && priority.between?(1, 9)
          errs
        end
      end
    end
  end
end
