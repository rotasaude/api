# Atenção psicossocial (ADR 0049): sem o interruptor utilizável (inclui o
# prontuário; sem cascata, contrato P22), /psychosocial/* responde
# feature_disabled. Lido fora da transação da cidade.
module Psychosocial
  module Gate
    KEY = "psychosocial_care".freeze

    module_function

    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
