# Interruptor do módulo 24a (ADR 0042; contrato §1). Rotas e job:
# usable? (ligado e com o prontuário utilizável). Código que roda na
# transação da cidade (TeamPopulation, IdentityRefresh): enabled? lê só
# city_features na plataforma.
module TerritoryRegistry
  module Gate
    KEY = "territory_registry".freeze

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
