# Item da requisição (ADR 0037): um exame do 21a numa amostra; um exame num item só.
class LabRequisitionItem < ApplicationRecord
  STATUSES = %w[pending typed released cancelled].freeze

  belongs_to :lab_requisition
  belongs_to :exam_order
  belongs_to :lab_exam_version
  belongs_to :lab_sample
  has_many :results, -> { order(:created_at, :id) }, class_name: "LabResult", inverse_of: :lab_requisition_item

  def active? = status != "cancelled"
end
