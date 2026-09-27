# Auditoria imutável (ADR-0014, ADR-0004), no banco da cidade. Eventos sobre
# objetos de plataforma vão para PlatformEvent via Platform.audit (Ruling R18).
# Só acréscimo (F-07.1): o trigger domain_events_guard (db/city_triggers.sql)
# aceita apenas marcar published_at uma vez — o IdempotentConsumer faz isso por
# update_all — e DELETE além da retenção de 12 meses (PurgeDomainEventsJob).
class DomainEvent < ApplicationRecord
  self.primary_key = :id

  validates :name, :occurred_at, presence: true

  scope :pending, -> { where(published_at: nil) }

  def readonly?
    persisted? || super
  end
end
