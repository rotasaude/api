# Valida um nó de condição (when) no PUBLISH (Gate). Semântico, além do JSON
# Schema: operador conhecido, gt/lt/gte/lte só em step integer ou variável
# numérica, eq/in no conjunto permitido, step referenciado existe. Mapa legado
# {step=>val} = validação por-par. Ver ADR-0009. (chore de validação —
# F-03.2/F-03.6)
#
# ADR 0027 (spec 2026-10-05 §4.3): `variables:` diz quais variáveis reservadas
# o LUGAR aceita (contratos §1). O padrão é nenhuma: decision_table e
# priority_when continuam só com passos.
module Protocols
  module Validation
    module Condition
      OPERATORS = Protocols::Condition::OPERATORS
      NUMERIC_OPERATORS = %w[gt lt gte lte].freeze
      VARIABLES = {
        "profile.age" => :number, "profile.sex" => :sex, "outcome.tier" => :text,
        "outcome.score" => :number, "outcome.priority" => :number, "citizen.neighborhood_id" => :uuid
      }.freeze
      SEXES = %w[female male].freeze
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

      module_function

      def errors(node, by_id, variables: [])
        return ["condition must be a non-empty object"] unless node.is_a?(Hash) && node.any?
        return legacy_errors(node, by_id, variables) unless operator_node?(node)

        op, operand = node.first
        case op.to_s
        when "eq", "in" then eq_in_errors(op.to_s, operand, by_id, variables)
        when *NUMERIC_OPERATORS then numeric_errors(op.to_s, operand, by_id, variables)
        when "all", "any"
          return ["condition '#{op}' operand must be a non-empty array"] unless operand.is_a?(Array) && operand.any?
          operand.flat_map { |sub| errors(sub, by_id, variables: variables) }
        when "not" then errors(operand, by_id, variables: variables)
        else ["unknown condition operator '#{op}'"]
        end
      end

      def step_id_collision_errors(steps)
        Array(steps).filter_map do |s|
          "step id '#{s["id"]}' collides with a condition operator" if OPERATORS.include?(s["id"].to_s)
        end
      end

      # ADR 0027: nenhum passo pode ter id que comece por prefixo reservado — a
      # variável sempre venceria a resposta no contexto.
      def reserved_prefix_errors(steps)
        Array(steps).filter_map do |s|
          next unless s.is_a?(Hash) && reserved?(s["id"])

          "step id '#{s["id"]}' uses a reserved prefix (profile., outcome., citizen.)"
        end
      end

      def operator_node?(node)
        node.size == 1 && OPERATORS.include?(node.keys.first.to_s)
      end

      def reserved?(name) = Protocols::ConditionContext.reserved?(name)

      def eq_in_errors(op, operand, by_id, variables)
        return ["condition '#{op}' operand must be [step_id, value]"] unless operand.is_a?(Array) && operand.size == 2
        step_id, value = operand
        values = op == "in" ? Array(value) : [value]
        return variable_value_errors(op, step_id.to_s, values, variables) if reserved?(step_id)

        step = by_id[step_id.to_s]
        return ["condition '#{op}' references unknown step #{step_id}"] if step.nil?
        allowed = Answers.for(step)
        return [] if allowed.nil?
        values.map(&:to_s).reject { |v| allowed.include?(v) }
              .map { |v| "condition '#{op}' invalid answer '#{v}' for step #{step_id}" }
      end

      def numeric_errors(op, operand, by_id, variables)
        return ["condition '#{op}' operand must be [step_id, number]"] unless operand.is_a?(Array) && operand.size == 2
        name, threshold = operand
        errs = []
        if reserved?(name)
          errs.concat(variable_errors(name.to_s, variables))
          errs << "condition '#{op}' requires a numeric variable, got #{name}" if errs.empty? && VARIABLES[name.to_s] != :number
        else
          step = by_id[name.to_s]
          return ["condition '#{op}' references unknown step #{name}"] if step.nil?
          errs << "condition '#{op}' requires an integer step, got #{step["answer_type"]} for #{name}" unless step["answer_type"] == "integer"
        end
        errs << "condition '#{op}' threshold must be numeric" unless numeric?(threshold)
        errs
      end

      def variable_errors(name, variables)
        variables.include?(name) && VARIABLES.key?(name) ? [] : ["condition variable '#{name}' is not allowed here"]
      end

      def variable_value_errors(op, name, values, variables)
        errs = variable_errors(name, variables)
        return errs if errs.any?

        valid = case VARIABLES[name]
                when :sex then ->(v) { SEXES.include?(v.to_s) }
                when :uuid then ->(v) { v.to_s.match?(UUID) }
                when :number then ->(v) { numeric?(v) }
                else ->(_v) { true }
                end
        values.reject { |v| valid.call(v) }.map { |v| "condition '#{op}' invalid value '#{v}' for #{name}" }
      end

      def numeric?(value)
        value.is_a?(Numeric) || !Float(value.to_s, exception: false).nil?
      end

      def legacy_errors(map, by_id, variables)
        map.flat_map do |step_id, answer|
          next variable_value_errors("eq", step_id.to_s, [answer], variables) if reserved?(step_id)

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
