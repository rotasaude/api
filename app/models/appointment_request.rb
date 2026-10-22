# Pedido de agendamento (ADR 0019, ADR 0029): nasce do desfecho return/referred
# com unidade ou da triagem (kind triage, regra do protocolo); a recepção da
# unidade de destino marca o horário. Só acréscimo (trigger); a origem nunca
# muda; a unidade de destino nula recebe uma unidade uma vez. Módulo 23
# (ADR 0040, contrato §11 T4): também nasce da inscrição numa linha de
# cuidado (kind care_line), sem triagem raiz.
class AppointmentRequest < ApplicationRecord
  KINDS = %w[return referral triage screening care_line].freeze
  STATUSES = %w[open scheduled closed].freeze
  CLOSED_REASONS = %w[fulfilled citizen_cancelled dismissed moved consent_revoked].freeze
  PRIORITIES = %w[routine priority].freeze
  PERIODS = %w[morning afternoon any].freeze
  RESCHEDULE_REASONS = %w[work health transport other].freeze
  DUE_IN_DAYS = 30

  belongs_to :origin_attendance, class_name: "Attendance", inverse_of: :appointment_request, optional: true
  belongs_to :origin_triage, class_name: "Triage", optional: true
  belongs_to :origin_screening, class_name: "Screening", optional: true
  belongs_to :citizen
  # Sem triagem raiz: o pedido da linha de cuidado e o que nasce de um
  # atendimento sem raiz (o do horário da linha). ck_appointment_requests_care_line
  # exige a raiz em todos os outros (o da triagem sempre a tem).
  belongs_to :root_triage, class_name: "Triage", optional: true
  belongs_to :origin_care_line_enrollment, class_name: "CareLineEnrollment", optional: true
  belongs_to :origin_unit, class_name: "HealthUnit", optional: true
  belongs_to :target_unit, class_name: "HealthUnit", optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  # Pedido movido de unidade (api#29): o novo aponta para o antigo.
  belongs_to :moved_from_request, class_name: "AppointmentRequest", optional: true
  has_many :appointments, foreign_key: :request_id, inverse_of: :request, dependent: :restrict_with_error
  has_many :request_triages, class_name: "AppointmentRequestTriage", foreign_key: :request_id, inverse_of: :request,
                             dependent: :restrict_with_error

  # Sem data indicada no desfecho (o atendimento não registra uma): +30 dias.
  attribute :due_on, :date, default: -> { Time.zone.today + DUE_IN_DAYS }

  scope :live_requests, -> { where(status: %w[open scheduled]) }

  def latest_appointment
    appointments.max_by(&:created_at)
  end

  def origin
    return "triage" if origin_triage_id
    return "care_line" if origin_care_line_enrollment_id

    "attendance"
  end
end
