# Auditoria imutável de tudo que aconteceu no domínio. Ver ADR-0003 e ADR-0009.
# Não atualize linhas existentes; o único UPDATE legítimo é em `published_at`.
class DomainEvent < ApplicationRecord
  self.primary_key = :id

  validates :name, :aggregate_type, :aggregate_id, :occurred_at, presence: true

  scope :pending, -> { where(published_at: nil) }
  scope :for_aggregate, ->(aggregate) {
    where(aggregate_type: aggregate.class.name, aggregate_id: aggregate.id.to_s)
  }

  def mark_published!
    update_column(:published_at, Time.current)
  end
end
