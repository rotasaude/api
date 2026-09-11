# Avaliador de condições do motor de protocolos. Módulo puro — ver ADR-0009.
# eq/in/gt/lt/all/any/not; um `when` que não seja nó-operador de chave única é
# tratado como mapa legado {step_id => value} (AND de eq). Runtime total:
# nunca levanta — operando ausente/não-numérico ou nó inválido => false.
# Cada branch de operador é type-guarded (operand precisa ser Array/Hash conforme
# o operador); operando malformado (nil, String, Integer, array curto) => false.
module Protocols
  module Condition
    OPERATORS = %w[eq in gt lt all any not].freeze

    module_function

    def eval(node, answers)
      return false unless node.is_a?(Hash)
      return legacy_all_eq(node, answers) unless operator_node?(node)

      op, operand = node.first
      case op.to_s
      when "eq"  then operand.is_a?(Array) && answers[operand[0].to_s] == operand[1].to_s
      when "in"  then operand.is_a?(Array) && Array(operand[1]).map(&:to_s).include?(answers[operand[0].to_s])
      when "gt"  then operand.is_a?(Array) && numeric(answers[operand[0].to_s]) { |v| v > Float(operand[1]) }
      when "lt"  then operand.is_a?(Array) && numeric(answers[operand[0].to_s]) { |v| v < Float(operand[1]) }
      when "all" then operand.is_a?(Array) && operand.all? { |n| eval(n, answers) }
      when "any" then operand.is_a?(Array) && operand.any? { |n| eval(n, answers) }
      when "not" then operand.is_a?(Hash) && !eval(operand, answers)
      else false
      end
    end

    # NOTE: colisão conhecida — um `when` legado de chave única para um step com
    # nome de operador (ex.: {"eq" => "true"}) é lido como o OPERADOR eq, não como
    # mapa legado. Remédio = proibir step id == nome de operador na validação de
    # publish (deferido, F-03.2 out-of-scope). Runtime é total de qualquer forma.
    def operator_node?(node)
      node.size == 1 && OPERATORS.include?(node.keys.first.to_s)
    end

    def legacy_all_eq(map, answers)
      return false if map.empty?
      map.all? { |step_id, expected| answers[step_id.to_s] == expected.to_s }
    end

    def numeric(raw)
      yield Float(raw)
    rescue ArgumentError, TypeError
      false
    end
  end
end
