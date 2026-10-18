# Aparelho do laboratório (ADR 0038): identificado na HL7 pelo hl7_equipment_id (OBX-18).
class LabInstrument < ApplicationRecord
  belongs_to :exam_provider

  scope :active, -> { where(active: true) }

  def inspect = "#<LabInstrument id=#{id} name=#{name} sector=#{sector}>"
end
