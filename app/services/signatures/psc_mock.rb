module Signatures
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
