# Consumidor de consent.revoked: visibilidade leve — incrementa a métrica de
# revogações para o painel de consentimento da cidade. Auditoria bruta já está
# em domain_events. (F-07.15)
class RecordConsentRevocationJob < ApplicationJob
  include IdempotentConsumer
  queue_as :reports

  def handle(conversation_id:, **)
    DashboardMetric.bump!(
      municipality_id: Current.municipality_id,
      dimension: "consents_revoked",
      period: Time.current.to_date.iso8601,
      key: "total"
    )
  end
end
