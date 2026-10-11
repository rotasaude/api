# "Obter números do SNCR" (contrato §4; Divergência D2: devolve também o state,
# que o dashboard guarda e reenvia no callback).
module Sncr
  class RequestsController < BaseController
    def create
      result = StartRequest.call(user: Current.user, kind: body["kind"].to_s, return_to: body["return_to"])
      return failure(result) if result.failure?

      render json: { authorize_url: result.payload[:authorize_url], state: result.payload[:state] }
    end
  end
end
