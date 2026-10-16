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
  # ADR 0037 (Desvio 4, B8): a retificação acrescenta; o vigente é o que
  # nenhum outro substituiu. Nota #2: só substitui resultado do mesmo pedido.
  belongs_to :replaces_result, class_name: "ExamResult", optional: true
  scope :current, -> { where.not(id: ExamResult.unscoped.where.not(replaces_result_id: nil).select(:replaces_result_id)) }

  validate :replaces_same_order, if: :replaces_result_id?

  def values_list = JSON.parse(values)
  def external? = origin == "external"
  # Sem valores nem o crítico (dispatch da Task 13: nunca em log nem erro).
  def inspect = "#<ExamResult id=#{id} origin=#{origin} source=#{source}>"

  private

  def replaces_same_order
    errors.add(:replaces_result, :invalid) unless exam_order_id && replaces_result&.exam_order_id == exam_order_id
  end
end
