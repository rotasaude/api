# Interruptor do módulo 28 (ADR 0046). Rotas e jobs: usable? (ligado e com o
# prontuário utilizável; o `requires` do catálogo já cobre isso). Consumidores
# de evento rodam na transação da cidade: enabled? lê só city_features na
# plataforma.
module DentalCare
  module Gate
    KEY = "dental_care".freeze

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
