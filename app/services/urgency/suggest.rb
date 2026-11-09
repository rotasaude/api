# Cor sugerida pelo protocolo de classificação (ADR 0050; Desvio 10; §14
# Q1/Q3). Puro sobre a definição: as `classification_rules` sobre o contexto
# da linguagem de condição do 18, com a dor em `pain_scale` (fora de vitals;
# um `vitals.pain_score` que chegue é descartado) e o perfil (idade e sexo). A
# queixa nunca entra na condição. Vale a cor mais grave entre as regras que
# casam; no empate, a primeira da lista. Sem protocolo, nil.
module Urgency
  module Suggest
    module_function

    def call(vitals:, pain_scale:, profile:, protocol: ActiveProtocol.current)
      return nil if protocol.nil?

      context = Protocols::ConditionContext.build(vitals: without_pain_score(vitals), profile: profile || {},
                                                  answers: pain_scale.nil? ? {} : { "pain_scale" => pain_scale.to_s })
      best = nil
      Array(protocol.definition&.dig("classification_rules")).each do |rule|
        next unless rule.is_a?(Hash) && (rank = Catalog::COLORS.index(rule["color"]))
        next unless Protocols::Condition.eval(rule["when"], context)

        best = [ rank, rule ] if best.nil? || rank < best.first
      end
      best && { color: best.last["color"], criterion: best.last["criterion"], rule_id: best.last["id"] }
    end

    def without_pain_score(vitals)
      vitals.is_a?(Hash) ? vitals.reject { |key, _| key.to_s == "pain_score" } : {}
    end
  end
end
