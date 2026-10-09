# app/controllers/signatures/batches_controller.rb
# "Assinar todas" (contrato §5): começa o lote; o resultado sai no callback.
module Signatures
  class BatchesController < BaseController
    def create
      result = StartBatch.call(user: Current.user, request_ids: body["request_ids"], return_to: body["return_to"])
      return failure(result) if result.failure?

      render json: result.payload
    end
  end
end
