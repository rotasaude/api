# Interruptor do módulo 25 (ADR 0043; contrato §1). Rotas e jobs diários:
# usable? (ligado; sem pré-requisito). Consumidores de evento rodam na
# transação da cidade: enabled? lê só city_features na plataforma. As rotas de
# consulta ao prontuário (linha do tempo, ficha) exigem também o prontuário
# utilizável: consultation_usable?.
module Surveillance
  module Gate
    KEY = "surveillance".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end

    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end

    def consultation_usable?(city)
      usable?(city) && ClinicalRecord::Gate.usable?(city)
    end
  end
end
