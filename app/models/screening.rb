# Escuta inicial (ADR 0030; spec 2026-10-07 §3): uma por atendimento, com
# revisões só de acréscimo. O atendimento não ganha estado: continua waiting
# durante e depois da escuta. Transições guardadas por screenings_guard.
class Screening < ApplicationRecord
  STATUSES = %w[in_progress completed abandoned].freeze
  DESTINATIONS = %w[same_day schedule oriented referred].freeze

  belongs_to :attendance
  belongs_to :started_by_user, class_name: "User"
  belongs_to :professional_link
  belongs_to :current_revision, class_name: "ScreeningRevision", optional: true
  belongs_to :appointment_request, optional: true
  has_many :revisions, class_name: "ScreeningRevision", dependent: :restrict_with_error

  scope :completed_screenings, -> { where(status: "completed") }
  scope :in_progress_screenings, -> { where(status: "in_progress") }

  def completed? = status == "completed"
  def in_progress? = status == "in_progress"
end
