# app/commands/signatures/close_session.rb
# Encerrar a sessão do turno (contrato §4). O token é descartado (a API v0 não
# tem revogação de token).
module Signatures
  module CloseSession
    module_function

    def call(user:, now: Time.current)
      SignatureSession.active.where(user_id: user.id).update_all(status: "revoked", updated_at: now)
      Result.ok
    end
  end
end
