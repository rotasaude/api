# app/commands/signatures/park.rb
# O pedido continua pending, agora com o motivo (ADR 0032; spec §5). Falha
# passageira soma uma tentativa. O status `failed` nunca é produzido.
module Signatures
  module Park
    module_function

    def call(request, reason, transient: false, now: Time.current)
      attributes = { reason_code: reason, updated_at: now }
      attributes[:attempts] = request.attempts + 1 if transient
      request.update!(attributes)
      DomainEvents.publish("signature.failed", request_id: request.id, reason_code: reason)
      request
    end
  end
end
