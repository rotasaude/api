# Volta do login do SNCR pelo dashboard (contrato §4; Divergência D1):
# { state, session_id } ou { state, error }.
module Sncr
  class OauthController < BaseController
    def callback
      result = CompleteRequest.call(user: Current.user, state: body["state"], session_id: body["session_id"], error: body["error"])
      return failure(result) if result.failure?

      render json: result.payload.slice(:kind, :received, :batch_id, :return_to)
    end
  end
end
