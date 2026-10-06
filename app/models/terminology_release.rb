# app/models/terminology_release.rb
# Uma versão importada de terminologia nacional (ADR 0028; spec 2026-10-05
# §4). Escrita só por Terminology::Import; imutabilidade por trigger.
class TerminologyRelease < PlatformRecord
  KINDS = %w[cid10 ciap2 sigtap].freeze
  STATUSES = %w[importing active superseded failed].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :version, :source_sha256, :imported_by, :imported_at, presence: true

  scope :active, -> { where(status: "active") }
end
