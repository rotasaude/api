# Liberador ligado a um laboratório (ADR 0037): RT (technical_lead) e
# substituto (technical_deputy), um ativo de cada por laboratório. Encerrar = ended_at.
class LabReleaser < ApplicationRecord
  belongs_to :user
  belongs_to :exam_provider
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :ended_by_user, class_name: "User", optional: true

  scope :active, -> { where(ended_at: nil) }
end
