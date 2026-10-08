# Problema avaliado na consulta (ou mudado por adendo), com a situação no
# momento (ADR 0031; spec §4). Só acréscimo.
class ConsultationProblem < ApplicationRecord
  ACTIONS = %w[evaluate add resolve correct_onset].freeze

  belongs_to :consultation
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true
  belongs_to :patient_problem
end
