# Motivo de rejeição de amostra do laboratório (spec §4).
class LabRejectionReason < ApplicationRecord
  belongs_to :exam_provider

  scope :active, -> { where(active: true) }
end
