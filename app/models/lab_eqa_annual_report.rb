# Relatório anual do CEQ (C-E24): do programa no ano; PDF em exam_files (cifrado). Só acréscimo.
class LabEqaAnnualReport < ApplicationRecord
  PURPOSE = "eqa_annual_report".freeze # marca do upload feito em /lab/eqa/uploads

  belongs_to :exam_provider
  belongs_to :file, class_name: "ExamFile"
  belongs_to :recorded_by_user, class_name: "User"
end
