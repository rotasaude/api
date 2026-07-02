# Consumidor de consent.revoked: apaga o conteúdo clínico da triage abortada
# por revogação (LGPD), mantendo a casca de auditoria. Ver ADR-0005/0020. (F-07.15)
class AnonymizeRevokedTriageJob < ApplicationJob
  include IdempotentConsumer
  queue_as :housekeeping

  def handle(conversation_id:, **)
    Triage.where(conversation_id: conversation_id, status: :aborted_by_revocation).find_each do |t|
      t.update_columns(
        answers: {}, outcome: nil, tier: nil, priority: nil,
        current_step: nil, updated_at: Time.current
      )
    end
  end
end
