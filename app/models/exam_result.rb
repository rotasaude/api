# Resultado (ADR 0036): imutável (trigger); valores em JSON cifrado
# (`[{ key|null, label, value, unit|null, loinc|null }]`); PDF em exam_files.
class ExamResult < ApplicationRecord
  encrypts :values

  belongs_to :exam_order, optional: true
  belongs_to :patient
  belongs_to :pdf_file, class_name: "ExamFile"
  belongs_to :exam_provider, optional: true
  belongs_to :registered_by_user, class_name: "User", optional: true
  belongs_to :registered_by_provider, class_name: "ExamProvider", optional: true
  belongs_to :consultation, optional: true

  def values_list = JSON.parse(values)
  def external? = origin == "external"
  # Sem valores nem o crítico (dispatch da Task 13: nunca em log nem erro).
  def inspect = "#<ExamResult id=#{id} origin=#{origin} source=#{source}>"
end
