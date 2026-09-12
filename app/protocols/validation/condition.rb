# Valida um nó de condição (when) no PUBLISH (Gate). Semântico, além do JSON
# Schema: operador conhecido, gt/lt só em step integer, eq/in no conjunto
# permitido, step referenciado existe. Mapa legado {step=>val} = validação
# por-par. Ver ADR-0009. (chore de validação — F-03.2/F-03.6)
module Protocols
  module Validation
    module Condition
      OPERATORS = Protocols::Condition::OPERATORS

      module_function

      def errors(node, by_id)
        return ["condition must be a non-empty object"] unless node.is_a?(Hash) && node.any?
        return legacy_errors(node, by_id) unless operator_node?(node)

        op, operand = node.first
        case op.to_s
        when "eq", "in" then eq_in_errors(op.to_s, operand, by_id)
        when "gt", "lt" then gt_lt_errors(op.to_s, operand, by_id)
        when "all", "any"
          return ["condition '#{op}' operand must be an array"] unless operand.is_a?(Array)
          operand.flat_map { |sub| errors(sub, by_id) }
        when "not" then errors(operand, by_id)
        else ["unknown condition operator '#{op}'"]
        end
      end

      def step_id_collision_errors(steps)
        Array(steps).filter_map do |s|
          "step id '#{s["id"]}' collides with a condition operator" if OPERATORS.include?(s["id"].to_s)
        end
      end

      def operator_node?(node)
        node.size == 1 && OPERATORS.include?(node.keys.first.to_s)
      end

      def eq_in_errors(op, operand, by_id)
        return ["condition '#{op}' operand must be [step_id, value]"] unless operand.is_a?(Array) && operand.size == 2
        step_id, value = operand
        step = by_id[step_id.to_s]
        return ["condition '#{op}' references unknown step #{step_id}"] if step.nil?
        allowed = Answers.for(step)
        return [] if allowed.nil?
        values = op == "in" ? Array(value) : [value]
        values.map(&:to_s).reject { |v| allowed.include?(v) }
              .map { |v| "condition '#{op}' invalid answer '#{v}' for step #{step_id}" }
      end

      def gt_lt_errors(op, operand, by_id)
        return ["condition '#{op}' operand must be [step_id, number]"] unless operand.is_a?(Array) && operand.size == 2
        step_id, threshold = operand
        step = by_id[step_id.to_s]
        return ["condition '#{op}' references unknown step #{step_id}"] if step.nil?
        errs = []
        errs << "condition '#{op}' requires an integer step, got #{step["answer_type"]} for #{step_id}" unless step["answer_type"] == "integer"
        errs << "condition '#{op}' threshold must be numeric" unless threshold.is_a?(Numeric) || Float(threshold.to_s, exception: false)
        errs
      end

      def legacy_errors(map, by_id)
        map.flat_map do |step_id, answer|
          step = by_id[step_id.to_s]
          next ["decision_table rule references unknown step #{step_id}"] if step.nil?
          allowed = Answers.for(step)
          next [] if allowed.nil?
          allowed.include?(answer.to_s) ? [] : ["decision_table invalid answer '#{answer}' for step #{step_id}"]
        end
      end
    end
  end
end
