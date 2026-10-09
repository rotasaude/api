# app/controllers/signatures/requests_controller.rb
# Pendentes de assinatura do próprio autor e volta ao papel (contrato §5, §13;
# NGS2.02.06). A lista é sempre das pendentes (o filtro pedido é ignorado).
module Signatures
  class RequestsController < BaseController
    LIMIT = 200

    def index
      rows = SignatureRequest.pending.where(author_user_id: Current.user.id).order(:created_at, :id).limit(LIMIT).to_a
      render json: { items: Json.requests(rows) }
    end

    def return_to_paper
      result = ReturnToPaper.call(request_id: params[:id], by: Current.user, reason: body["reason"])
      return failure(result, not_found: :not_found) if result.failure?

      render json: Json.requests([ result.payload[:request] ]).sole
    end
  end
end
