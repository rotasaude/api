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
      if record_processed_event_duplicate?(event_id)
        # Já processado antes (dedup). Se aquele processamento, por qualquer
        # motivo, não deixou o DomainEvent marcado (ex.: entrega anterior a
        # este fix), marcamos agora — um redispatch de um evento já tratado
        # não deve continuar pending para sempre.
        mark_domain_event_published(event_id)
      else
        handle(**payload.symbolize_keys)
        mark_domain_event_published(event_id)
      end
    end
  end

  def handle(**)
    raise NotImplementedError, "#{self.class.name} must implement #handle(**payload)"
  end

  private

  # Só a inserção do dedup row pode ser "já processado" — não #handle. Por
  # isso o rescue mora AQUI, num savepoint próprio (transaction requires_new),
  # não em volta do #handle no perform: uma RecordNotUnique que #handle
  # levante por conta própria (ex.: uma constraint de domínio) não é essa
  # duplicata e precisa propagar (rollback da transação inteira do
  # with_city, sem marcar published) em vez de ser engolida aqui.
  #
  # requires_new (SAVEPOINT) importa: sem ele, a violação de unicidade deixa
  # a conexão Postgres em "current transaction is aborted" e qualquer query
  # seguinte na MESMA transação (inclusive o mark_domain_event_published do
  # caminho de duplicata) levantaria PG::InFailedSqlTransaction.
  def record_processed_event_duplicate?(event_id)
    ApplicationRecord.transaction(requires_new: true) do
      ProcessedEvent.create!(
        event_id: event_id,
        consumer: self.class.name,
        processed_at: Time.current
      )
    end
    false
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[#{self.class.name}] duplicate event=#{event_id}")
    true
  end

  # Atômico (M1 fix round): where(published_at: nil).update_all evita a
  # janela de corrida do antigo find_by + mark_published! (leitura e escrita
  # separadas). Best-effort: se o DomainEvent já foi purgado
  # (PurgeDomainEventsJob), o update_all roda contra zero linhas — no-op, não
  # levanta.
  def mark_domain_event_published(event_id)
    DomainEvent.where(id: event_id, published_at: nil).update_all(published_at: Time.current)
  end
end
