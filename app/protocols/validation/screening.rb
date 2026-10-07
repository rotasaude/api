# Gate da variante kind "screening" (ADR 0030; spec §3.3; contratos §1): só
# regras { when, color }, até 50; o when aceita vitals.*, complaint.ciap2 e
# profile.*. Nome reservado: acolhimento. Total para qualquer entrada.
module Protocols
  module Validation
    module Screening
      NAME = "acolhimento".freeze
      COLORS = %w[red yellow green blue].freeze
      MAX_RULES = 50
      VARIABLES = (Condition::VARIABLES.keys.grep(/\A(vitals|complaint)\./) + %w[profile.age profile.sex]).freeze

      module_function

      def screening?(definition) = definition.is_a?(Hash) && definition["kind"] == "screening"

      def call(definition)
        return [] unless screening?(definition)

        errors = []
        errors << "screening protocol must be named '#{NAME}'" unless definition["name"] == NAME
        rules = definition["risk_rules"]
        return errors << "risk_rules must be an array" unless rules.is_a?(Array)
        return errors << "risk_rules must have 1 to #{MAX_RULES} rules" unless rules.size.between?(1, MAX_RULES)

        rules.each_with_index do |rule, index|
          next errors << "risk_rules[#{index}] must be an object" unless rule.is_a?(Hash)

          errors << "risk_rules[#{index}].color must be one of #{COLORS.join(', ')}" unless COLORS.include?(rule["color"])
          errors.concat(Condition.errors(rule["when"], {}, variables: VARIABLES).map { |e| "risk_rules[#{index}].when: #{e}" })
        end
        errors
      end

      # Protocolo de triagem nunca usa o nome do acolhimento.
      def reserved_name_errors(definition)
        return [] unless definition.is_a?(Hash) && !screening?(definition) && definition["name"] == NAME

        [ "name '#{NAME}' is reserved for the screening protocol" ]
      end
    end
  end
end
