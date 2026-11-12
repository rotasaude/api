# Interruptor do módulo 24b (ADR 0052): visita domiciliar. Utilizável = ligado
# e com o cadastro territorial utilizável pelo próprio critério da plataforma
# (IBGE e UF contam, ao contrário do TerritoryRegistry::Gate; W-4). Lido fora
# da transação da cidade.
module HomeVisits
  module Gate
    KEY = "home_visits".freeze

    module_function

    def usable?(city)
      return false if city.nil? || city.id.nil?

      Platform::Features.usable?(city, KEY)
    end
  end
end
