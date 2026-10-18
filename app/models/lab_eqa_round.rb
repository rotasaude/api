# Rodada do controle externo (CEQ; ADR 0038): só acréscimo; relatório anual em exam_files (cifrado).
class LabEqaRound < ApplicationRecord
  ADEQUACY = %w[adequate inadequate].freeze

  belongs_to :exam_provider
  belongs_to :recorded_by_user, class_name: "User"
  belongs_to :annual_report_file, class_name: "ExamFile", optional: true
end
