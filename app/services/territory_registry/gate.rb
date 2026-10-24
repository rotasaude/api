# Interruptor do módulo 24a (ADR 0042; contrato §1). Rotas e job:
# usable? (ligado e com o prontuário utilizável; IBGE/UF não contam). Código que roda na
# transação da cidade (TeamPopulation, IdentityRefresh): enabled? lê só
# city_features na plataforma.
module TerritoryRegistry
  module Gate
    KEY = "territory_registry".freeze

    module_function

    # O que falta no perfil da cidade (contrato §14 L20) não fecha as rotas:
    # aparece no maintenance (missing/usable) e a ficha fica "não gerada"
    # (city_profile_incomplete) — o mesmo mecanismo do procedure_billing.
    PROFILE_MISSING = %w[ibge_code_missing uf_missing].freeze

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY) && (Platform::Features.missing(city, KEY) - PROFILE_MISSING).empty?
    end

    def enabled?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.enabled?(city, KEY)
    end
  end
end
