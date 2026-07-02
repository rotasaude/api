# Consumidor de consent.revoked: visibilidade leve — incrementa a métrica de
# revogações para o painel de consentimento da cidade. Auditoria bruta já está
# em domain_events. (F-07.15)
class RecordConsentRevocationJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  # conversation_id chega no payload mas NÃO é usado: a métrica é agregada por
  # cidade (não por conversa). O escopo de tenant vem do Current.municipality_id
  # setado pelo with_tenant do IdempotentConsumer. Não transformar em métrica
  # por-conversa.
  def handle(conversation_id:, **)
    DashboardMetric.bump!(
      municipality_id: Current.municipality_id,
      dimension: "consents_revoked",
      period: Time.current.to_date.iso8601,
      key: "total"
    )
  end
end
