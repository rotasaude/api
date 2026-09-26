# Horário marcado dentro de um pedido (ADR 0019). Remarcar = linha nova;
# o que foi marcado nunca muda (trigger).
class Appointment < ApplicationRecord
  STATUSES = %w[scheduled confirmed checked_in cancelled_by_citizen expired no_show].freeze
  LIVE = %w[scheduled confirmed].freeze
  ENDED = %w[checked_in cancelled_by_citizen expired no_show].freeze
  CONFIRMATION_LEAD = 24.hours
  BORN_CONFIRMED_WITHIN = 48.hours
  MAX_AHEAD = 180.days

  belongs_to :request, class_name: "AppointmentRequest", inverse_of: :appointments
  belongs_to :citizen
  belongs_to :health_unit
  belongs_to :scheduled_by_user, class_name: "User"
  has_one :attendance

  scope :live, -> { where(status: LIVE) }

  def ended?
    ENDED.include?(status)
  end

  def today?
    scheduled_at.in_time_zone.to_date == Time.zone.today
  end
end
