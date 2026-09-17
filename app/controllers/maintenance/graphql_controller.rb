# Endpoint único da API de manutenção (spec §8): POST, uma operação por
# requisição, sem lote. GET não existe — query em URL vai parar em log e cache.
module Maintenance
  class GraphqlController < BaseController
    # Dois limites, propósitos diferentes: o de QUERY bounds o que o parser vê
    # (profundidade, complexidade); o de BODY bounds o que o processo lê do
    # socket, ponto — o que inclui `variables`, que o cap de query sozinho não
    # alcança (uma query minúscula com um `variables` de megabytes passaria
    # ilesa pelo primeiro limite). O de body é checado primeiro e é mais largo
    # de propósito: ele é o teto absoluto da requisição inteira.
    MAX_QUERY_BYTES = 10_000
    MAX_BODY_BYTES = 64_000
    INTROSPECTION = /\b__(schema|type)\b/

    def execute
      return head(:payload_too_large) if request.raw_post.bytesize > MAX_BODY_BYTES

      query = params[:query].to_s
      return head(:payload_too_large) if query.bytesize > MAX_QUERY_BYTES

      # Introspecção só em development: em ambiente publicado o schema é lido do
      # SDL em `contracts` (ADR-0015), não do endpoint. A checagem é aqui, e não
      # em Schema.disable_introspection_entry_points, porque aquela roda uma vez
      # no carregamento da classe — congelaria a decisão do ambiente que estava
      # ativo quando a classe carregou.
      if Rota.deployed? && query.match?(INTROSPECTION)
        return render(json: { errors: [ { message: "introspecção desligada em ambiente publicado" } ] }, status: :ok)
      end

      result = Schema.execute(
        query,
        variables: query_variables,
        operation_name: params[:operationName],
        context: {
          maintainer: current_maintainer,
          maintainer_session: Current.maintainer_session,
          credential: Current.maintenance_credential,
          request_id: request.request_id
        }
      )

      render json: result
    end

    private

    # Minor (fix round 2): `params[:variables]` cru não serve ao executor.
    # Cliente que manda `variables` como STRING JSON (é o que graphiql e vários
    # clientes fazem) levantava ArgumentError — 500 numa query legítima. E um
    # objeto aninhado chega como ActionController::Parameters, que só por sorte
    # se comporta como Hash na leitura: `to_unsafe_h` devolve o Hash de verdade,
    # em qualquer profundidade. Sem filtro de parâmetro, de propósito — quem
    # decide o que é aceitável aqui é o schema, campo a campo.
    def query_variables
      raw = params[:variables]

      case raw
      when ActionController::Parameters then raw.to_unsafe_h
      when String then raw.strip.empty? ? {} : JSON.parse(raw)
      when Hash then raw
      else {}
      end
    rescue JSON::ParserError
      {}
    end
  end
end
