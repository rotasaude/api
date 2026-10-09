# app/controllers/signatures/sessions_controller.rb
# Sessão do turno (contrato §4).
module Signatures
  class SessionsController < BaseController
    def create
      result = StartSession.call(user: Current.user, return_to: body["return_to"])
      return failure(result) if result.failure?

      render json: result.payload
    end

    def show
      render json: Json.session(SignatureSession.usable_for(Current.user.id))
    end

    def destroy
      CloseSession.call(user: Current.user)
      head :no_content
    end
  end
end
