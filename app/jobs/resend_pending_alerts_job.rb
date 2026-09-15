# Rede de segurança: re-enfileira AlertMunicipalityJob para eventos
# triage.urgent com published_at IS NULL. Roda a cada 5min (recurring.yml).
# Idempotência por consumidor (ADR-0005) garante que duplicatas sumam.
#
# Só redespacha eventos com mais de 5min (occurred_at): um evento mais novo
# pode só estar com o subscriber ainda enfileirado/rodando pelo caminho normal
# de publish (published_at é marcado quando o consumer TERMINA, não quando
# enfileira — ver IdempotentConsumer). Sem essa janela, o resend correria
# com o publish normal.
class ResendPendingAlertsJob < ApplicationJob
  prepend EachCityJob
  queue_as :urgent

  RESEND_AFTER = 5.minutes

  def perform
    DomainEvent.pending.where(name: "triage.urgent").where("occurred_at < ?", RESEND_AFTER.ago).find_each do |event|
      DomainEvents.redispatch(event)
    end
  end
end
