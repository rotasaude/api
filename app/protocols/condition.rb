# Avaliador de condições do motor de protocolos. Módulo puro — ver ADR-0009.
# eq/in/gt/lt/gte/lte/all/any/not; um `when` que não seja nó-operador de chave
# única é tratado como mapa legado {step_id => value} (AND de eq). Runtime
# total: nunca levanta — operando ausente/não-numérico ou nó inválido => false.
# Cada branch de operador é type-guarded (operand precisa ser Array/Hash conforme
# o operador); operando malformado (nil, String, Integer, array curto) => false.
#
# ADR 0027: o segundo argumento é um contexto plano — as respostas
# {step_id => valor}, como sempre, ou o hash de Protocols::ConditionContext,
# que junta as variáveis reservadas profile.*/outcome.*/citizen.*.
module Protocols
  module Condition
    OPERATORS = %w[eq in gt lt gte lte all any not].freeze

    module_function

    def eval(node, context)
      return false unless node.is_a?(Hash)
      return legacy_all_eq(node, context) unless operator_node?(node)

      op, operand = node.first
      case op.to_s
      when "eq"  then operand.is_a?(Array) && context[operand[0].to_s] == operand[1].to_s
      when "in"  then operand.is_a?(Array) && Array(operand[1]).map(&:to_s).include?(context[operand[0].to_s])
      when "gt"  then compare(context, operand) { |value, threshold| value > threshold }
      when "lt"  then compare(context, operand) { |value, threshold| value < threshold }
      when "gte" then compare(context, operand) { |value, threshold| value >= threshold }
      when "lte" then compare(context, operand) { |value, threshold| value <= threshold }
      when "all" then operand.is_a?(Array) && operand.all? { |n| eval(n, context) }
      when "any" then operand.is_a?(Array) && operand.any? { |n| eval(n, context) }
      when "not" then operand.is_a?(Hash) && !eval(operand, context)
      else false
      end
    end

    # NOTE: colisão conhecida — um `when` legado de chave única para um step com
    # nome de operador (ex.: {"eq" => "true"}) é lido como o OPERADOR eq, não como
    # mapa legado. O gate recusa step id == nome de operador
    # (Validation::Condition.step_id_collision_errors). Runtime é total.
    def operator_node?(node)
      node.size == 1 && OPERATORS.include?(node.keys.first.to_s)
    end

    def legacy_all_eq(map, context)
      return false if map.empty?
      map.all? { |step_id, expected| context[step_id.to_s] == expected.to_s }
    end

    def compare(context, operand)
      return false unless operand.is_a?(Array) && operand.size >= 2

      numeric(context[operand[0].to_s]) { |value| yield value, Float(operand[1]) }
    end

    def numeric(raw)
      yield Float(raw)
    rescue ArgumentError, TypeError
      false
    end
  end
end
