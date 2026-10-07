# app/services/screenings/suggest.rb
# Cor sugerida com o protocolo ativo e o perfil do par (ADR 0030). O
# servidor sempre recalcula: a cor sugerida gravada nunca vem do cliente.
module Screenings
  module Suggest
    NONE = { color: nil, matched: [], protocol_definition_id: nil }.freeze

    module_function

    def call(citizen:, ciap2_code:, vitals:, bmi:, on: Time.zone.today)
      protocol = ActiveProtocol.current
      return NONE.dup unless protocol

      result = RiskSuggestion.call({ vitals: vitals, bmi: bmi, ciap2_code: ciap2_code },
                                   citizen.profile_context(on: on), rules: protocol.definition["risk_rules"])
      result.merge(protocol_definition_id: protocol.id)
    end
  end
end
