# Item liberado desde a última corrida aceita, a revisar pelo RT (ADR 0038): decide uma vez; nota cifrada.
class LabQcReviewItem < ApplicationRecord
  DECISIONS = %w[pending kept rectify].freeze

  encrypts :note

  belongs_to :lab_qc_block
  belongs_to :lab_requisition_item
  belongs_to :decided_by_user, class_name: "User", optional: true

  def inspect = "#<LabQcReviewItem id=#{id} decision=#{decision}>"
end
