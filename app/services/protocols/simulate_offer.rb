# Simulador do editor (ADR 0027; contratos §4.3). Avalia offer.eligibility e
# suggestions[].when de uma definição em edição contra um perfil, respostas e
# resultado de exemplo. Não grava nada. Definição inválida para offer/
# suggestions (schema ou gate) responde eligible false e suggestions [] com os
# errors — nunca 422 (o editor mostra o erro ao lado do construtor).
module Protocols
  module SimulateOffer
    module_function

    def call(definition:, profile: {}, answers: {}, outcome: {})
      definition = {} unless definition.is_a?(Hash)
      offer = definition["offer"].is_a?(Hash) ? definition["offer"] : {}
      eligibility = offer["eligibility"]
      errors = errors(definition)
      result = { eligible: false, eligibility_text: ConditionText.call(eligibility), suggestions: [], errors: errors,
                 warnings: SuggestionTargets.warnings(definition) }
      return result if errors.any?

      context = context(profile, answers, outcome)
      result.merge(
        eligible: eligibility.nil? || Condition.eval(eligibility, context),
        suggestions: Array(definition["suggestions"]).select { |s| s.is_a?(Hash) }
                                                    .map { |s| { protocol: s["protocol"], matches: Condition.eval(s["when"], context) } }
      )
    end

    def context(profile, answers, outcome)
      profile = ConditionContext.symbolize(profile)
      ConditionContext.build(
        answers: answers, outcome: outcome,
        profile: { age: Integer(profile[:age], exception: false), sex: profile[:sex] },
        citizen: { neighborhood_id: profile[:neighborhood_id] }
      )
    end

    def errors(definition)
      schema = Validation::Schema.call(definition).select { |e| e.start_with?("schema: /offer", "schema: /suggestions") }
      schema.any? ? schema : Validation::Offer.call(definition)
    end
  end
end
