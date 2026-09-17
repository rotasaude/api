# Schema da API de manutenção (spec §8). Nesta fatia responde só `me`.
#
# Os limites não são enfeite: o endpoint é servido na internet pública e um
# mantenedor autenticado tem poderes totais, então uma query fundo demais ou
# complexa demais é problema mesmo vinda de dentro.
module Maintenance
  class Schema < GraphQL::Schema
    query Types::QueryType

    max_depth 10
    max_complexity 200

    def self.unauthorized_object(error)
      raise GraphQL::ExecutionError, "não autorizado: #{error.type.graphql_name}"
    end
  end
end
