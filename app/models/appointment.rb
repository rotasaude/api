# Horário marcado dentro de um pedido (ADR 0019). Remarcar = linha nova;
# o que foi marcado nunca muda (trigger).
class Appointment < ApplicationRecord
  STATUSES = %w[scheduled confirmed checked_in cancelled_by_citizen expired no_show moved].freeze
  LIVE = %w[scheduled confirmed].freeze
  ENDED = %w[checked_in cancelled_by_citizen expired no_show moved].freeze
  CONFIRMATION_LEAD = 24.hours
  BORN_CONFIRMED_WITHIN = 48.hours
  MAX_AHEAD = 180.days
  BOOKING_KINDS = %w[slot fit_in legacy].freeze
  # "Ativo" para a trava e para as vagas (ADR 0029): o check-in também ocupa.
  ACTIVE = %w[scheduled confirmed checked_in].freeze
  # Horário livre (legacy) não tem fim; para "cidadão sem dois horários
  # sobrepostos" ele ocupa 15 minutos.
  LEGACY_SPAN = 15.minutes
  MIN_FIT_IN_REASON = 10
  RESCHEDULE_CANCEL_REASON = "Remarcação pedida pelo cidadão".freeze
  # Exclusão LGPD (ADR 0026): texto fixo, nunca vai para evento.
  ERASURE_CANCEL_REASON = "Exclusão do cadastro pedida pelo cidadão".freeze

  belongs_to :request, class_name: "AppointmentRequest", inverse_of: :appointments
  belongs_to :citizen
  belongs_to :health_unit
  belongs_to :scheduled_by_user, class_name: "User"
  # Horário movido de unidade (api#29): o novo aponta para o antigo.
  belongs_to :moved_from_appointment, class_name: "Appointment", optional: true
  has_one :attendance
  belongs_to :professional, optional: true
  belongs_to :shift, class_name: "ProfessionalShift", optional: true
  has_one :notice, class_name: "AppointmentNotice", dependent: :restrict_with_error

  def fit_in? = booking_kind == "fit_in"
  def effective_ends_at = ends_at || scheduled_at + LEGACY_SPAN

  scope :live, -> { where(status: LIVE) }

  def ended?
    ENDED.include?(status)
  end

  def today?
    scheduled_at.in_time_zone.to_date == Time.zone.today
  end
end
