# Trilha do exame (ADR 0036): só acréscimo (trigger). O motivo é cifrado e
# nunca sai em evento de domínio nem em log.
class ExamOrderEvent < ApplicationRecord
  KINDS = %w[requested authorized denied scheduled collected resulted acknowledged escalated cancelled].freeze
  ESCALATION_REASONS = %w[overdue critical unlinked_requester].freeze

  encrypts :reason

  belongs_to :exam_order
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :actor_provider, class_name: "ExamProvider", optional: true

  validates :kind, inclusion: { in: KINDS }

  def inspect = "#<ExamOrderEvent id=#{id} kind=#{kind} exam_order_id=#{exam_order_id}>"
end
