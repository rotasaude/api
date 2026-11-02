# Interruptor do módulo 29 (ADR 0047): sala de vacina. Requer record_mode:record.
module Vaccination
  module Gate
    KEY = "vaccination".freeze

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
