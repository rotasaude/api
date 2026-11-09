# Urgência (UPA, ADR 0050): sem o interruptor utilizável (inclui o prontuário;
# sem cascata, como no CAPS), /urgency/* responde feature_disabled. Lido fora
# da transação da cidade.
module Urgency
  module Gate
    KEY = "urgency_care".freeze

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
