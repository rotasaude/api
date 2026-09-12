# Auditoria platform-scope (ADR-0012, ADR-0014), na PLATAFORMA — sem coluna de
# tenant (ao contrário de DomainEvent, que ainda carrega municipality_id
# nullable até a Task 5 trocar o destino de Platform.audit).
class PlatformEvent < PlatformRecord
  validates :name, :occurred_at, presence: true

  scope :pending, -> { where(published_at: nil) }

  def mark_published!
    update_column(:published_at, Time.current)
  end
end
