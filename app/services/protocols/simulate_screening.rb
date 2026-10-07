# Simulador do editor para o protocolo de acolhimento (ADR 0030; contrato §9):
# a cor que a definição EM EDIÇÃO sugeriria para sinais, queixa e perfil de
# exemplo. Não grava; definição ou sinais inválidos voltam em errors (200).
module Protocols
  module SimulateScreening
    NOT_SCREENING = "definition is not a screening protocol".freeze

    module_function

    def call(definition:, vitals: {}, ciap2_code: nil, profile: {})
      empty = { suggested_color: nil, matched_rules: [], errors: [], warnings: [] }
      return empty.merge(errors: [ SimulateOffer::NOT_AN_OBJECT ]) unless definition.is_a?(Hash)
      return empty.merge(errors: [ NOT_SCREENING ]) unless Validation::Screening.screening?(definition)

      errors = Validation::Schema.call(definition)
      errors = Validation::Screening.call(definition) if errors.empty?
      return empty.merge(errors: errors) if errors.any?

      parsed = Screenings::VitalSigns.parse(vitals)
      return empty.merge(errors: [ "vitals: #{parsed.reason} #{parsed.details[:field]}".strip ]) if parsed.failure?

      profile = ConditionContext.symbolize(profile)
      rules = definition["risk_rules"]
      result = Screenings::RiskSuggestion.call(
        { vitals: parsed.payload[:values], bmi: parsed.payload[:bmi], ciap2_code: ciap2_code.to_s.strip.upcase.presence },
        { age: Integer(profile[:age].to_s, 10, exception: false), sex: profile[:sex] }, rules: rules
      )
      empty.merge(suggested_color: result[:color],
                  matched_rules: Screenings::Json.matched_rules_for(result[:matched], rules))
    end
  end
end
