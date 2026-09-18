# Catálogo de cidades para a API de manutenção (spec §8).
#
# Lê SÓ o banco de plataforma: nenhuma conexão de cidade é aberta aqui, e é por
# isso que listar 40 cidades custa uma query, não 40 conexões. O caminho para
# dentro de uma cidade é `city(slug:)`, e só ele.
#
# O escopo do token é aplicado AQUI e em `city(slug:)` — os dois pontos onde
# cidade é escolhida. Nenhum resolver de subárvore repete a regra.
module Maintenance
  class CityCatalogQuery
    def self.call(credential:, status: nil)
      scope = City.order(:slug)
      scope = scope.where(status: status) if status.present?

      scope.select { |city| credential.allows_city?(city.slug) }
    end
  end
end
