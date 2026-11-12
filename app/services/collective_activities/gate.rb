# Interruptor do módulo 24b (ADR 0052): atividade coletiva. Requer o prontuário
# utilizável. Lido fora da transação da cidade.
module CollectiveActivities
  module Gate
    KEY = "collective_activities".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
