# app/commands/signatures/return_to_paper.rb
# Volta ao papel pelo autor (ADR 0032; spec §5; contrato §5). FOR UPDATE: se o
# job está assinando, espera e vê o resultado (signed → not_pending). O job
# segura o pedido durante a chamada HTTP ao PSC (até minutos): lock_timeout
# curto transforma a espera longa em not_pending, em vez de prender a
# requisição. A nota é cifrada (encrypts) e nunca vai a log ou evento.
module Signatures
  module ReturnToPaper
    LOCK_TIMEOUT = "5s".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def call(request_id:, by:, reason:, now: Time.current)
      note = reason.is_a?(String) ? reason.squish : ""
      unless note.size.between?(SignatureRequest::MIN_RETURN_NOTE, SignatureRequest::MAX_RETURN_NOTE)
        return Result.fail(:invalid_reason)
      end
      return Result.fail(:not_found) unless request_id.is_a?(String) && request_id.match?(UUID)

      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        request = SignatureRequest.lock.find_by(id: request_id)
        next Result.fail(:not_found) unless request
        next Result.fail(:not_author) unless request.author_user_id == by.id
        next Result.fail(:not_pending) unless request.pending?

        Result.ok(request: ToPaper.call(request, reason_code: "user_request", note: note, now: now))
      end
    rescue ActiveRecord::LockWaitTimeout
      Result.fail(:not_pending) # o job está assinando agora
    end
  end
end
