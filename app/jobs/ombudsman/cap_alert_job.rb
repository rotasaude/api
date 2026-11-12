# Consumidor de ombudsman.anonymous_cap_reached (ADR 0051; contrato §4; §16
# Q21): o primeiro bloqueio do dia pelo teto da denúncia anônima. Roda na
# transação da cidade (IdempotentConsumer): nada de SMTP aqui, só enfileira o
# Ombudsman::MailJob. O payload é {}; o dia vem do próprio evento
# (`occurred_at` no fuso da cidade), para que o consumo depois da meia-noite
# ainda conte o dia do bloqueio. Nunca atribui Current.city.
module Ombudsman
  class CapAlertJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def perform(event_id:, **rest)
      @event_id = event_id
      super(event_id: event_id, **rest)
    end

    def handle(**)
      occurred_at = DomainEvent.where(id: @event_id).pick(:occurred_at) || Time.current
      MailJob.perform_later(city_slug: Current.city.slug, kind: "anonymous_cap",
                            ref: occurred_at.in_time_zone.to_date.iso8601)
    end
  end
end
