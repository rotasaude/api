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

  # ADR 0032 (revisão): PSC simulado. Só existe fora de produção; ligado, a
  # cidade usa apenas o PSC simulado (provider `simulated`).
  module PscMock
    KEY = "signature_psc_mock".freeze

    module_function

    def on?(city, env: Rails.env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY, env: env)
    end
  end
end
