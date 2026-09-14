# Consumidor de consent.revoked: visibilidade leve — incrementa a métrica de
# revogações para o painel de consentimento da cidade. Auditoria bruta já está
# em domain_events. (F-07.15)
class RecordConsentRevocationJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  # conversation_id chega no payload mas NÃO é usado: a métrica é agregada por
  # cidade (não por conversa). A cidade é a conexão aberta pelo with_city do
  # IdempotentConsumer. Não transformar em métrica por-conversa.
  def handle(conversation_id:, **)
    DashboardMetric.bump!(
      dimension: "consents_revoked",
      period: Time.current.to_date.iso8601,
      key: "total"
    )
  end
end
