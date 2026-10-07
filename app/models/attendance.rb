# Atendimento numa unidade (ADR 0018, 0019): nasce no check-in a partir de
# uma triagem OU de um horário; waiting → in_care (chamada) → closed.
class Attendance < ApplicationRecord
  METHODS = %w[code cpf_exception].freeze
  STATUSES = %w[waiting in_care closed].freeze
  OUTCOMES = %w[discharged referred return left scheduled_from_screening oriented].freeze
  # ADR 0030: destino da escuta → desfecho que fecha o atendimento de waiting.
  SCREENING_OUTCOMES = { "schedule" => "scheduled_from_screening", "oriented" => "oriented", "referred" => "referred" }.freeze
  # O que a rota de desfecho (Attendances::Close) aceita: os de escuta só saem de Screenings::Complete.
  CLOSE_OUTCOMES = %w[discharged referred return left].freeze

  belongs_to :triage, optional: true
  belongs_to :appointment, optional: true
  belongs_to :citizen
  belongs_to :health_unit
  belongs_to :checked_in_by_user, class_name: "User"
  belongs_to :called_by_user, class_name: "User", optional: true
  belongs_to :referral_unit, class_name: "HealthUnit", optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  # O pedido vigente do atendimento: um pedido movido de unidade (api#29) fica
  # encerrado como `moved` e o novo, ligado a ele, é o que vale.
  has_one :appointment_request, -> { where("appointment_requests.closed_reason IS DISTINCT FROM 'moved'") },
          foreign_key: :origin_attendance_id, inverse_of: :origin_attendance
  has_one :screening, dependent: :restrict_with_error

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

  # Bairro do caso para a unidade de referência (ADR 0023): o copiado na
  # triagem raiz; sem triagem raiz (nem pela cadeia do horário), o bairro
  # atual do cidadão. Triagem sem bairro continua sem bairro.
  def territory_neighborhood_id
    root = root_triage
    root ? root.neighborhood_id : citizen&.neighborhood_id
  end
end
