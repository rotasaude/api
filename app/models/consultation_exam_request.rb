# Exame solicitado (SIGTAP grupo 02, com a competência) e a justificativa
# CID-10 opcional (ADR 0031; Task 1). Adendo cancela com linha `cancelled`.
class ConsultationExamRequest < ApplicationRecord
  STATUSES = %w[requested cancelled].freeze

  belongs_to :consultation
  belongs_to :addendum, class_name: "ConsultationAddendum", optional: true
end
