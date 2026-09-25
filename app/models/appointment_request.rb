# Pedido de agendamento (ADR 0019): nasce do desfecho return/referred com
# unidade; a recepção da unidade de destino marca o horário. Só acréscimo
# (trigger); a origem nunca muda.
class AppointmentRequest < ApplicationRecord
  KINDS = %w[return referral].freeze
  STATUSES = %w[open scheduled closed].freeze
  CLOSED_REASONS = %w[fulfilled citizen_cancelled dismissed].freeze

  belongs_to :origin_attendance, class_name: "Attendance", inverse_of: :appointment_request
  belongs_to :citizen
  belongs_to :root_triage, class_name: "Triage"
  belongs_to :origin_unit, class_name: "HealthUnit"
  belongs_to :target_unit, class_name: "HealthUnit"
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_many :appointments, foreign_key: :request_id, inverse_of: :request, dependent: :restrict_with_error

  scope :live_requests, -> { where(status: %w[open scheduled]) }

  def latest_appointment
    appointments.max_by(&:created_at)
  end
end
