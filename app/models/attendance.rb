# Atendimento numa unidade (ADR 0018, 0019): nasce no check-in a partir de
# uma triagem OU de um horário; waiting → in_care (chamada) → closed.
# Módulo 32a (ADR 0050; plano, Desvio 2): ou da chegada na UPA (`walk_in`),
# sem triagem, sem horário e sem o par do wpda — a pessoa é o Patient.
class Attendance < ApplicationRecord
  METHODS = %w[code cpf_exception urgency_reception].freeze
  ORIGIN_KINDS = %w[triage appointment walk_in].freeze
  STATUSES = %w[waiting in_care closed].freeze
  OUTCOMES = %w[discharged referred return left scheduled_from_screening oriented].freeze
  # ADR 0030: destino da escuta → desfecho que fecha o atendimento de waiting.
  SCREENING_OUTCOMES = { "schedule" => "scheduled_from_screening", "oriented" => "oriented", "referred" => "referred" }.freeze
  # O que a rota de desfecho (Attendances::Close) aceita: os de escuta só saem de Screenings::Complete.
  CLOSE_OUTCOMES = %w[discharged referred return left].freeze

  belongs_to :triage, optional: true
  belongs_to :appointment, optional: true
  belongs_to :citizen, optional: true
  belongs_to :patient, optional: true
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
  has_one :consultation, dependent: :restrict_with_error
  # Módulo 32a: o encontro da urgência, 1:1 com o walk_in (modelo na Task 4).
  has_one :urgency_encounter

  # O banco também deduz (rota_attendance_insert_guard), para as linhas cruas.
  before_validation { self.origin_kind ||= triage_id ? "triage" : (appointment_id ? "appointment" : nil) }

  validates :origin_kind, inclusion: { in: ORIGIN_KINDS }
  validates :citizen, presence: true, unless: :walk_in?

  scope :open_attendances, -> { where(status: %w[waiting in_care]) }
  scope :waiting, -> { where(status: "waiting") }
  scope :in_care, -> { where(status: "in_care") }

  def open?
    status != "closed"
  end

  def walk_in? = origin_kind == "walk_in"

  # Quem é atendido: o par do wpda no 13, o paciente no walk_in.
  def person = citizen || patient

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
