# Interruptor do envio da regulação à RNDS (módulo 26c; molde Rnds::Gate).
module Regulation
  module RndsGate
    KEY = "rnds_regulation".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end

    # Só o interruptor (sem credencial nem catálogo): a tela de situação e a
    # lista abrem com a credencial recusada (Q10).
    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end
  end
end
