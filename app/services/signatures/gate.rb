# A assinatura digital só existe com o interruptor digital_signature LIGADO e
# UTILIZÁVEL (ADR 0032; requer clinical_record utilizável). Relido da
# plataforma a cada chamada.
module Signatures
  module Gate
    KEY = "digital_signature".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
