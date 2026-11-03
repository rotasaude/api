# Tratamento Fora de Domicílio (ADR 0048): sem o interruptor utilizável (inclui sanitary_transport), /tfd/* responde feature_disabled.
module Tfd
  module Gate
    KEY = "tfd".freeze

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
