# Schema da API de manutenção (spec §8). Nesta fatia responde só `me`.
#
# Os limites não são enfeite: o endpoint é servido na internet pública e um
# mantenedor autenticado tem poderes totais, então uma query fundo demais ou
# complexa demais é problema mesmo vinda de dentro.
module Maintenance
  class Schema < GraphQL::Schema
    query Types::QueryType
    mutation Types::MutationType

    max_depth 10
    max_complexity 200

    # Limite de TEMPO (spec §8: 10 s), que faltava. Profundidade e complexidade
    # limitam a FORMA da query; nenhuma das duas impede uma query rasa e
    # simples de segurar um processo Puma numa conexão lenta de cidade — este é
    # o limite que interrompe a execução e devolve erro no campo.
    use GraphQL::Schema::Timeout, max_seconds: 10

    def self.unauthorized_object(error)
      raise GraphQL::ExecutionError, "não autorizado: #{error.type.graphql_name}"
    end
  end
end
