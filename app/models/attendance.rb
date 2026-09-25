# Atendimento numa unidade (ADR 0018, 0019): nasce no check-in a partir de
# uma triagem OU de um horário; waiting → in_care (chamada) → closed.
class Attendance < ApplicationRecord
  METHODS = %w[code cpf_exception].freeze
  STATUSES = %w[waiting in_care closed].freeze
  OUTCOMES = %w[discharged referred return left].freeze

  belongs_to :triage, optional: true
  belongs_to :appointment, optional: true
  belongs_to :citizen
  belongs_to :health_unit
  belongs_to :checked_in_by_user, class_name: "User"
  belongs_to :called_by_user, class_name: "User", optional: true
  belongs_to :referral_unit, class_name: "HealthUnit", optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_one :appointment_request, foreign_key: :origin_attendance_id, inverse_of: :origin_attendance

  scope :open_attendances, -> { where(status: %w[waiting in_care]) }
  scope :waiting, -> { where(status: "waiting") }
  scope :in_care, -> { where(status: "in_care") }

  def open?
    status != "closed"
  end

  # A triagem que começou a cadeia: a própria, ou a do pedido do horário.
  def root_triage
    triage || appointment&.request&.root_triage
  end

  def priority
    root_triage&.priority
  end
end
