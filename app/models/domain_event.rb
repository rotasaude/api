# Auditoria imutável (ADR-0014, ADR-0004). municipality_id pode ser NULL em
# eventos platform-scope (ADR-0012; emenda aplicada no Phase 4).
class DomainEvent < ApplicationRecord
  self.primary_key = :id

  validates :name, :occurred_at, presence: true

  scope :pending, -> { where(published_at: nil) }

  def mark_published!
    update_column(:published_at, Time.current)
  end
end
