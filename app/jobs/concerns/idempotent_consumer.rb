# Garante exactly-once por consumidor. Ver ADR-0005.
#
# Subclasses implementam #consume(event); o concern cuida do gate.
# IMPORTANTE: efeitos colaterais externos (HTTP, fila de e-mail) NÃO podem
# ficar dentro de #consume — eles vão como job separado, ver ADR-0014.
module IdempotentConsumer
  extend ActiveSupport::Concern

  class AlreadyProcessed < StandardError; end

  def perform(event_id)
    event = DomainEvent.find(event_id)
    consumer = self.class.name

    ApplicationRecord.transaction do
      ProcessedEvent.create!(consumer: consumer, event_id: event.id, processed_at: Time.current)
      consume(event)
    end

    event.mark_published! if event.published_at.nil?
  rescue ActiveRecord::RecordNotUnique
    # Já processado por outra execução — silenciar é o comportamento correto.
    Rails.logger.info("[#{self.class.name}] skip duplicate event=#{event_id}")
  end

  def consume(_event)
    raise NotImplementedError, "#{self.class.name} must implement #consume(event)"
  end
end
