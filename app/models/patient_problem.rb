# Estado atual de um problema do paciente (ADR 0031; spec §3). Resultado de
# patient_problem_events: só Patients::ApplyProblemEvent escreve aqui, e o
# trigger patient_problems_guard exige o evento na mesma transação.
class PatientProblem < ApplicationRecord
  TERMINOLOGIES = %w[ciap2 cid10].freeze
  STATUSES = %w[active resolved].freeze
  PRECISIONS = %w[day month year].freeze

  belongs_to :patient
  has_many :events, class_name: "PatientProblemEvent", dependent: :restrict_with_error

  scope :active_problems, -> { where(status: "active") }

  def active? = status == "active"
end
