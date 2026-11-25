# BNAFAR simulado (módulo 27b, Q6): só existe fora de produção; ligado, o
# envio fala com o fake-bnafar (sem validade).
module Bnafar
  module Mock
    KEY = "bnafar_mock".freeze

    module_function

    def on?(city, env: Rails.env)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY, env: env)
    end
  end
end
