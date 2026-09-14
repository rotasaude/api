# Exactly-once per consumer, scoped to a city (ADR-0005).
# Subclasses implementam #handle(**kwargs). Efeitos HTTP NÃO entram aqui
# (ver ADR-0005); fora-de-banda fica para job dedicado.
module IdempotentConsumer
  extend ActiveSupport::Concern
  include CityScopedJob

  class AlreadyProcessed < StandardError; end

  def perform(event_id:, event_name:, city_slug:, payload:)
    with_city(city_slug) do
      ProcessedEvent.create!(
        event_id: event_id,
        consumer: self.class.name,
        processed_at: Time.current
      )
      handle(**payload.symbolize_keys)
    end
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[#{self.class.name}] duplicate event=#{event_id}")
  end

  def handle(**)
    raise NotImplementedError, "#{self.class.name} must implement #handle(**payload)"
  end
end
