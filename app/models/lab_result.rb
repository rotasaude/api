# Resultado do laboratório (ADR 0037): só acréscimo (trigger); valor cifrado.
# Vale a última linha do componente; escolher acrescenta cópia (Desvio 9).
class LabResult < ApplicationRecord
  FLAGS = %w[normal low high critical_low critical_high].freeze
  CRITICAL = %w[critical_low critical_high].freeze

  encrypts :value

  belongs_to :lab_requisition_item
  belongs_to :lab_hl7_receipt, optional: true
  belongs_to :entered_by_user, class_name: "User", optional: true
  belongs_to :chosen_from, class_name: "LabResult", optional: true
  belongs_to :reagent_lot, class_name: "LabSupplyLot", optional: true
  has_many :critical_notices, class_name: "LabCriticalNotice", inverse_of: :lab_result

  def critical? = CRITICAL.include?(flag)
  def inspect = "#<LabResult id=#{id} analyte_key=#{analyte_key} source=#{source} chosen=#{chosen}>"
end
