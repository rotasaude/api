# Ouvidoria do SUS municipal (ADR 0051): sem o interruptor utilizável,
# /ombudsman/* responde feature_disabled. Lido fora da transação da cidade.
module Ombudsman
  module Gate
    KEY = "ombudsman".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
