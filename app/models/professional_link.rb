# Vínculo do profissional com a unidade, com a ocupação (CBO) daquele lugar
# (ADR 0021). Só acréscimo: encerrar grava ended_at, nada se apaga.
class ProfessionalLink < ApplicationRecord
  belongs_to :professional
  belongs_to :health_unit
  belongs_to :started_by_user, class_name: "User"
  belongs_to :ended_by_user, class_name: "User", optional: true
  has_many :shifts, class_name: "ProfessionalShift", dependent: :restrict_with_error

  scope :active, -> { where(ended_at: nil) }

  # Deprecated codes remain valid for existing rows (append-only table); only
  # creation of a new link is checked against the catalogue. OpenLink already
  # refuses unknown/deprecated codes before this runs.
  validates :cbo_code, inclusion: { in: ->(_) { Professionals::Cbo.all.map(&:code) } }, on: :create

  def active? = ended_at.nil?
end
