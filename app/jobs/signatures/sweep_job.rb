# app/jobs/signatures/sweep_job.rb
# Varredura da assinatura em cada cidade (ADR 0032; Desvio 8), a cada 10 min
# (config/recurring.yml): interruptor não utilizável (digital_signature,
# clinical_record ou record_mode) → pendentes voltam ao papel
# (feature_disabled); sessões vencidas → expired; states vencidos há mais de
# 1 dia apagados. Nunca atribui Current.city (EachCityJob).
module Signatures
  class SweepJob < ApplicationJob
    prepend EachCityJob

    queue_as :housekeeping

    def perform
      now = Time.current
      return_pending_to_paper(now) unless Gate.usable?(Current.city)
      SignatureSession.active.where(expires_at: ..now).update_all(status: "expired", updated_at: now)
      SignatureOauthState.where(expires_at: ...(now - 1.day)).delete_all
    end

    private

    # Um pedido por transação; o que o job/lote está assinando fica para a
    # próxima volta (SKIP LOCKED) — e o job, ao tocá-lo, já o devolve ao papel.
    def return_pending_to_paper(now)
      SignatureRequest.pending.pluck(:id).each do |id|
        ApplicationRecord.transaction do
          request = SignatureRequest.lock("FOR UPDATE SKIP LOCKED").find_by(id: id)
          ToPaper.call(request, reason_code: "feature_disabled", now: now) if request&.pending?
        end
      end
    end
  end
end
