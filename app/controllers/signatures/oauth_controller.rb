# app/controllers/signatures/oauth_controller.rb
# Volta do PSC pelo dashboard (contrato §4, §13): { state, code } ou
# { state, error }. O return_to guardado com o state volta no sucesso e em
# toda falha depois de achar o state do próprio usuário.
module Signatures
  class OauthController < BaseController
    def callback
      result = CompleteOauth.call(user: Current.user, state: body["state"], code: body["code"], error: body["error"])
      return failure(result) if result.failure?

      payload = result.payload
      render json: { purpose: payload[:purpose], result: rendered(payload[:purpose], payload[:record]),
                     return_to: payload[:return_to] }
    end

    private

    def rendered(purpose, record)
      case purpose
      when "link" then Json.certificate(record)
      when "session" then { expires_at: record.expires_at.iso8601 }
      when "batch" then record
      end
    end
  end
end
