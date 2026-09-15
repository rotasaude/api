# Exactly-once per consumer, scoped to a city (ADR-0005).
# Subclasses implementam #handle(**kwargs). Efeitos HTTP NÃO entram aqui
# (ver ADR-0005); fora-de-banda fica para job dedicado.
#
# published_at (DomainEvent): marcado aqui, não em publish/redispatch — o
# evento só conta como "publicado" quando o CONSUMER TERMINA com sucesso, não
# quando é apenas enfileirado. Isso é o que dá sentido a
# DomainEvent.pending (ResendPendingAlertsJob): um evento cujo consumer nunca
# rodou (ou rodou e falhou) continua pending e é candidato a redispatch.
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
      mark_domain_event_published(event_id)
    end
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[#{self.class.name}] duplicate event=#{event_id}")
    # Já processado antes (dedup). Se aquele processamento, por qualquer
    # motivo, não deixou o DomainEvent marcado (ex.: entrega anterior a este
    # fix), marcamos agora — um redispatch de um evento já tratado não deve
    # continuar pending para sempre. mark_domain_event_published já é
    # idempotente (não sobrescreve published_at existente).
    with_city(city_slug) { mark_domain_event_published(event_id) }
  end

  def handle(**)
    raise NotImplementedError, "#{self.class.name} must implement #handle(**payload)"
  end

  private

  # Best-effort: se o DomainEvent já foi purgado (PurgeDomainEventsJob), não
  # há nada para marcar — o consumer já fez seu trabalho, o registro de
  # auditoria é que não existe mais.
  def mark_domain_event_published(event_id)
    event = DomainEvent.find_by(id: event_id)
    event.mark_published! if event && event.published_at.nil?
  end
end
