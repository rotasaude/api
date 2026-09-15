# Rede de segurança: re-enfileira AlertMunicipalityJob para eventos
# triage.urgent com published_at IS NULL. Roda a cada 5min (recurring.yml).
# Idempotência por consumidor (ADR-0005) garante que duplicatas sumam.
#
# Janela [RESEND_MAX_AGE, RESEND_MIN_AGE] em occurred_at:
#   - mínimo 5min: um evento mais novo pode só estar com o subscriber ainda
#     enfileirado/rodando pelo caminho normal de publish (published_at é
#     marcado quando o consumer TERMINA, não quando enfileira — ver
#     IdempotentConsumer). Sem esse mínimo, o resend correria com o publish
#     normal.
#   - máximo 24h: o dedup por (consumer, event_id) em ProcessedEvent só vale
#     enquanto a linha existir, e PurgeProcessedEventsJob a apaga depois de 60
#     dias — enquanto DomainEvent (12 meses, PurgeDomainEventsJob) sobrevive
#     muito mais. Sem um teto aqui, a primeira vez que este job roda depois de
#     deploy redespacharia TODO pending acumulado (60d–12m de eventos velhos,
#     inclusive um cujo handle falha sempre, redespachado a cada 5min por um
#     ano) de uma vez. 24h fica bem dentro da janela de dedup e ainda cobre
#     qualquer falha razoável de infra/consumer.
class ResendPendingAlertsJob < ApplicationJob
  prepend EachCityJob
  queue_as :urgent

  RESEND_MIN_AGE = 5.minutes
  RESEND_MAX_AGE = 24.hours

  def perform
    DomainEvent.pending.where(name: "triage.urgent")
               .where("occurred_at < ?", RESEND_MIN_AGE.ago)
               .where("occurred_at > ?", RESEND_MAX_AGE.ago)
               .find_each do |event|
      DomainEvents.redispatch(event)
    end
  end
end
