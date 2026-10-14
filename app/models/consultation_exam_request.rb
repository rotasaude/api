# Exame solicitado (SIGTAP grupo 02, com a competência) e a justificativa
# CID-10 opcional (ADR 0031; Task 1). Adendo cancela com linha `cancelled`.
class ConsultationExamRequest < ApplicationRecord
  STATUSES = %w[requested cancelled].freeze
  # ADR 0036: prioridade do pedido (vira a do exame rastreado).
  PRIORITIES = %w[routine urgent].freeze

  belongs_to :consultation
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true

  validates :priority, inclusion: { in: PRIORITIES }
end
