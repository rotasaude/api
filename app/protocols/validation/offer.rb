# app/protocols/validation/offer.rb
# Gate de offer e suggestions (ADR 0027; spec 2026-10-05 §4.2–§4.3; contratos
# §1). Cada lugar aceita só as suas variáveis reservadas; o `when` da sugestão
# também aceita os passos do próprio protocolo. Total para qualquer entrada: o
# simulador do dashboard chama isto com definição ainda em edição.
module Protocols
  module Validation
    module Offer
      ELIGIBILITY = %w[profile.age profile.sex].freeze
      SUGGESTION = %w[profile.age profile.sex outcome.tier outcome.score outcome.priority].freeze
      RESTRICTION = %w[profile.age profile.sex citizen.neighborhood_id].freeze

      module_function

      def call(definition)
        definition = {} unless definition.is_a?(Hash)
        offer = definition["offer"].is_a?(Hash) ? definition["offer"] : {}
        errors = []
        if offer.key?("eligibility")
          errors.concat(prefixed("offer.eligibility", Condition.errors(offer["eligibility"], {}, variables: ELIGIBILITY)))
        end
        days = offer["retake_after_days"]
        unless days.nil? || (days.is_a?(Integer) && days.positive?)
          errors << "offer.retake_after_days must be a positive integer"
        end
        errors.concat(suggestion_errors(definition))
      end

      def suggestion_errors(definition)
        suggestions = definition["suggestions"]
        return [] if suggestions.nil?
        return ["suggestions must be an array"] unless suggestions.is_a?(Array)

        by_id = Array(definition["steps"]).select { |s| s.is_a?(Hash) }.to_h { |s| [s["id"].to_s, s] }
        suggestions.each_with_index.flat_map do |suggestion, index|
          next ["suggestions[#{index}] must be an object"] unless suggestion.is_a?(Hash)

          errs = []
          errs << "suggestions[#{index}]: suggestion points to the protocol itself" if suggestion["protocol"].to_s == definition["name"].to_s
          errs + prefixed("suggestions[#{index}].when", Condition.errors(suggestion["when"], by_id, variables: SUGGESTION))
        end
      end

      def prefixed(place, errors) = errors.map { |error| "#{place}: #{error}" }
    end
  end
end
