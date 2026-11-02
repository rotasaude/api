# ADR 0047: RNDS simulada. Só existe fora de produção; ligada, o envio fala com
# o fake-rnds (sem validade).
module Rnds
  module Mock
    KEY = "rnds_mock".freeze

    module_function

    def on?(city, env: Rails.env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY, env: env)
    end
  end
end
