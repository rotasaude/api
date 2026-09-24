# Atendimento numa unidade, aberto pelo check-in a partir de uma triagem
# (ADR 0018). Só acréscimo, exceto encerrar uma vez (trigger).
class Attendance < ApplicationRecord
  METHODS = %w[code cpf_exception].freeze
  OUTCOMES = %w[discharged referred left].freeze

  belongs_to :triage
  belongs_to :citizen
  belongs_to :health_unit
  belongs_to :checked_in_by_user, class_name: "User"
  belongs_to :referral_unit, class_name: "HealthUnit", optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true

  scope :open_attendances, -> { where(status: "open") }

  def open?
    status == "open"
  end
end
