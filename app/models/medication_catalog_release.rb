# app/models/medication_catalog_release.rb
# Uma importação do CATMAT (ADR 0033): contagens da diferença; uma ativa.
# Escrita só por Medications::CatalogImport; transições por trigger.
class MedicationCatalogRelease < PlatformRecord
  STATUSES = %w[importing active superseded failed].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :imported_by, :imported_at, presence: true

  scope :active, -> { where(status: "active") }

  def self.current = active.order(activated_at: :desc).first
end
