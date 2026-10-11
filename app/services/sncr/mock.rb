# ADR 0034: SNCR simulado. Só existe fora de produção; ligado, a cidade pede
# números ao fake-sncr e usa só os números simulados do estoque.
module Sncr
  module Mock
    KEY = "sncr_mock".freeze

    module_function

    def on?(city, env: Rails.env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY, env: env)
    end
  end
end
