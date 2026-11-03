# Transporte sanitário (ADR 0048): sem o interruptor, /transport/* responde feature_disabled.
module Transport
  module Gate
    KEY = "sanitary_transport".freeze

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
