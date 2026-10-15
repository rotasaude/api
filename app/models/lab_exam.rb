# Exame adotado pelo laboratório (ADR 0037; spec §4): SIGTAP, setor, bancada,
# prazo de entrega e a versão vigente (as versões são imutáveis).
class LabExam < ApplicationRecord
  SECTORS = %w[biochemistry hematology immunology urinalysis parasitology microbiology].freeze

  belongs_to :exam_provider
  belongs_to :current_version, class_name: "LabExamVersion", optional: true
  has_many :versions, -> { order(:version) }, class_name: "LabExamVersion", inverse_of: :lab_exam

  validates :sector, inclusion: { in: SECTORS }
  validates :delivery_days, numericality: { only_integer: true, in: 1..90 }
end
