# Frase em português de uma condição (contratos §4.3), só para conferência no
# simulador: a frase da tela é do construtor do dashboard. Total.
module Protocols
  module ConditionText
    LABELS = {
      "profile.age" => "idade", "profile.sex" => "sexo", "outcome.tier" => "faixa", "outcome.score" => "pontuação",
      "outcome.priority" => "prioridade", "citizen.neighborhood_id" => "bairro",
      "vitals.systolic" => "pressão sistólica", "vitals.diastolic" => "pressão diastólica",
      "vitals.heart_rate" => "frequência cardíaca", "vitals.respiratory_rate" => "frequência respiratória",
      "vitals.temperature_c" => "temperatura", "vitals.spo2" => "saturação", "vitals.capillary_glucose" => "glicemia",
      "vitals.glucose_moment" => "momento da glicemia", "vitals.weight_kg" => "peso", "vitals.height_cm" => "altura",
      "vitals.bmi" => "IMC", "vitals.pain_score" => "dor", "complaint.ciap2" => "queixa (CIAP-2)"
    }.freeze
    VALUES = { "female" => "feminino", "male" => "masculino" }.freeze
    SYMBOLS = { "eq" => "=", "gt" => ">", "lt" => "<", "gte" => "≥", "lte" => "≤" }.freeze
    INVALID = "regra inválida".freeze

    module_function

    def call(node) = node.nil? ? "todos" : phrase(node, top: true)

    def phrase(node, top: false)
      return INVALID unless node.is_a?(Hash) && node.any?
      return group(node.map { |key, val| "#{label(key)} = #{value(val)}" }, " e ", top) unless Condition.operator_node?(node)

      op, operand = node.first
      case op.to_s
      when *SYMBOLS.keys
        pair?(operand) ? "#{label(operand[0])} #{SYMBOLS[op.to_s]} #{value(operand[1])}" : INVALID
      when "in"
        pair?(operand) ? "#{label(operand[0])} em #{Array(operand[1]).map { |v| value(v) }.join(', ')}" : INVALID
      when "all", "any"
        return INVALID unless operand.is_a?(Array) && operand.any?

        group(operand.map { |child| phrase(child) }, op.to_s == "all" ? " e " : " ou ", top)
      when "not" then "não (#{phrase(operand, top: true)})"
      else INVALID
      end
    end

    def pair?(operand) = operand.is_a?(Array) && operand.size == 2
    def group(parts, separator, top) = parts.size > 1 && !top ? "(#{parts.join(separator)})" : parts.join(separator)
    def label(name) = LABELS.fetch(name.to_s) { "resposta de #{name}" }
    def value(raw) = VALUES.fetch(raw.to_s, raw.to_s)
  end
end
