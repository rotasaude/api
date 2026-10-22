# Interruptor do módulo 23 (ADR 0040; contrato §1). Rotas e job diário:
# usable? (ligado e com o prontuário utilizável). Consumidores de evento
# rodam na transação da cidade: enabled? lê só city_features na plataforma.
module CareLines
  module Gate
    KEY = "care_lines".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end

    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end
  end
end
