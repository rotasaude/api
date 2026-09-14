# Auditoria imutável (ADR-0014, ADR-0004), no banco da cidade. Eventos sobre
# objetos de plataforma vão para PlatformEvent via Platform.audit (Ruling R18).
class DomainEvent < ApplicationRecord
  self.primary_key = :id

  validates :name, :occurred_at, presence: true

  scope :pending, -> { where(published_at: nil) }

  def mark_published!
    update_column(:published_at, Time.current)
  end
end
