# app/protocols/validation/scheduling.rb
# Gate de scheduling (ADR 0029; spec 2026-10-05 §5.1; contratos §1). O `when`
# aceita as variáveis de resultado e de perfil e os passos do próprio
# protocolo — o mesmo conjunto de suggestions[].when. Total para qualquer
# entrada: o editor do dashboard chama o gate com a definição em edição.
module Protocols
  module Validation
    module Scheduling
      VARIABLES = Offer::SUGGESTION

      module_function

      def call(definition)
        return [] unless definition.is_a?(Hash) && definition.key?("scheduling")

        rules = definition["scheduling"]
        return ["scheduling must be an array"] unless rules.is_a?(Array)

        by_id = Array(definition["steps"]).select { |s| s.is_a?(Hash) }.to_h { |s| [s["id"].to_s, s] }
        rules.each_with_index.flat_map do |rule, index|
          next ["scheduling[#{index}] must be an object"] unless rule.is_a?(Hash)

          Condition.errors(rule["when"], by_id, variables: VARIABLES).map { |error| "scheduling[#{index}].when: #{error}" }
        end
      end
    end
  end
end
