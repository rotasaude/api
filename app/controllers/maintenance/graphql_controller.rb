# Endpoint único da API de manutenção (spec §8): POST, uma operação por
# requisição, sem lote. GET não existe — query em URL vai parar em log e cache.
module Maintenance
  class GraphqlController < BaseController
    MAX_QUERY_BYTES = 10_000
    INTROSPECTION = /\b__(schema|type)\b/

    def execute
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
        variables: params[:variables] || {},
        operation_name: params[:operationName],
        context: {
          maintainer: current_maintainer,
          maintainer_session: Current.maintainer_session,
          request_id: request.request_id
        }
      )

      render json: result
    end
  end
end
