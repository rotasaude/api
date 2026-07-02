# Scoring semantics beyond JSON Schema: decision_table.when references and
# weighted priority_map / thresholds tier consistency.
module Protocols
  module Validation
    module Scoring
      def self.call(definition)
        scoring = definition["scoring"]
        return [] unless scoring.is_a?(Hash)

        case scoring["type"]
        when "weighted" then weighted_errors(scoring)
        when "decision_table" then decision_table_errors(scoring, definition["steps"] || [])
        else []
        end
      end

      def self.weighted_errors(scoring)
        thresholds = (scoring["thresholds"] || {}).keys.to_set
        (scoring["priority_map"] || {}).keys
          .reject { |tier| thresholds.include?(tier) }
          .map { |tier| "priority_map tier '#{tier}' not in thresholds" }
      end

      def self.decision_table_errors(scoring, steps)
        by_id = steps.to_h { |s| [s["id"], s] }
        Array(scoring["rules"]).flat_map { |rule| Condition.errors(rule["when"] || {}, by_id) }
      end
    end
  end
end
