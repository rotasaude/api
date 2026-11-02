# Interruptor do envio das doses à RNDS (ADR 0047).
module Rnds
  module Gate
    KEY = "rnds_immunization".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
