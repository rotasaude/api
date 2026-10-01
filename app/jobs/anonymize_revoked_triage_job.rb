# Consumidor de consent.revoked: apaga o conteúdo clínico da triage abortada
# por revogação (LGPD), mantendo a casca de auditoria. Ver ADR-0005/0003. (F-07.15)
# ADR 0024: apaga também as linhas de campanha do cidadão quando a conversa revogada é a mais recente dele.
# ADR 0026: apaga também a triagem concluída que não virou atendimento (a com atendimento fica retida).
# ADR 0023: apaga também o bairro copiado (única exceção do trigger triages_neighborhood_immutable).
class AnonymizeRevokedTriageJob < ApplicationJob
  include IdempotentConsumer
  queue_as :housekeeping

  def handle(conversation_id:, **)
    Triage.where(conversation_id: conversation_id, status: %w[aborted_by_revocation completed]).find_each do |t|
      Triages::Anonymize.call(t)
    end
    Campaigns::ForgetRevokedRecipients.call(conversation_id: conversation_id)
  end
end
