# Exactly-once per consumer + tenant scoping (ADR-0005 + emenda ADR-0020).
# Subclasses implementam #handle(**kwargs). Efeitos HTTP NÃO entram aqui
# (ver ADR-0014); fora-de-banda fica para job dedicado.
module IdempotentConsumer
  extend ActiveSupport::Concern
  include TenantScopedJob

  class AlreadyProcessed < StandardError; end

  def perform(event_id:, event_name:, municipality_id:, payload:)
    with_tenant(municipality_id) do
      ProcessedEvent.create!(
        event_id: event_id,
        consumer: self.class.name,
        municipality_id: municipality_id,
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
