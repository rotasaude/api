# Consumidor de consent.revoked: apaga o conteúdo clínico da triage abortada
# por revogação (LGPD), mantendo a casca de auditoria. Ver ADR-0005/0003. (F-07.15)
# ADR 0024: apaga também as linhas de campanha do cidadão quando a conversa revogada é a mais recente dele.
# ADR 0023: apaga também o bairro copiado (única exceção do trigger triages_neighborhood_immutable).
class AnonymizeRevokedTriageJob < ApplicationJob
  include IdempotentConsumer
  queue_as :housekeeping

  def handle(conversation_id:, **)
    Triage.where(conversation_id: conversation_id, status: :aborted_by_revocation).find_each do |t|
      t.update_columns(
        answers: {}, outcome: nil, tier: nil, priority: nil,
        current_step: nil, neighborhood_id: nil, updated_at: Time.current
      )
    end
    Campaigns::ForgetRevokedRecipients.call(conversation_id: conversation_id)
  end
end
