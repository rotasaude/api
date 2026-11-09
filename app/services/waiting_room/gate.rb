# Painel de chamada da sala de espera (ADR 0050): interruptor independente do
# prontuário. Sem ele utilizável, /waiting_room/* responde feature_disabled.
module WaitingRoom
  module Gate
    KEY = "waiting_room_display".freeze

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
