# app/services/screenings/risk_suggestion.rb
# Cor sugerida (ADR 0030; spec §3.3). Puro: recebe a revisão (sinais, IMC,
# CIAP-2), o perfil e as regras do protocolo assinado; devolve a cor mais
# grave entre as regras que casam e os índices de todas elas. Sinal ausente
# não entra no contexto, então a condição sobre ele é falsa.
module Screenings
  module RiskSuggestion
    COLORS = %w[red yellow green blue].freeze

    module_function

    def call(revision, profile, rules:)
      context = Protocols::ConditionContext.build(
        vitals: (revision[:vitals] || {}).merge("bmi" => revision[:bmi]),
        complaint: { ciap2: revision[:ciap2_code] }, profile: profile || {}
      )
      matched = Array(rules).each_with_index.filter_map do |rule, index|
        next unless rule.is_a?(Hash) && COLORS.include?(rule["color"])

        index if Protocols::Condition.eval(rule["when"], context)
      end
      color = matched.map { |index| rules[index]["color"] }.min_by { |c| COLORS.index(c) }
      { color: color, matched: matched }
    end
  end
end
