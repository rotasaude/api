# Bloqueio da liberação por aparelho e analito (ADR 0038): um ativo por par;
# uma ação corretiva; fecha uma vez, com ação (trigger).
class LabQcBlock < ApplicationRecord
  belongs_to :lab_instrument
  belongs_to :opened_by_run, class_name: "LabQcRun"
  belongs_to :closed_by_run, class_name: "LabQcRun", optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  belongs_to :corrective_action_by_user, class_name: "User", optional: true
  has_many :exceptions, class_name: "LabQcException", inverse_of: :lab_qc_block
  has_many :review_items, class_name: "LabQcReviewItem", inverse_of: :lab_qc_block

  scope :active, -> { where(closed_at: nil) }
end
