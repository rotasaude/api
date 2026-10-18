# Material de controle (ADR 0038): níveis e analitos (lab_exam_id + analyte_key).
class LabQcMaterial < ApplicationRecord
  belongs_to :exam_provider
  has_many :lots, -> { order(:created_at) }, class_name: "LabQcLot", inverse_of: :lab_qc_material

  def analyte_entry(key, exam_id: nil)
    analytes.find { |a| a["analyte_key"] == key.to_s && (exam_id.nil? || a["lab_exam_id"] == exam_id) }
  end
end
