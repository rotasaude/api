# Valor de controle (ADR 0038): só acréscimo; avaliado por Westgard na gravação. O valor nunca vai a log.
class LabQcValue < ApplicationRecord
  OUTCOMES = %w[ok warning reject].freeze

  belongs_to :lab_qc_run
  belongs_to :lab_qc_lot
  belongs_to :lab_qc_target
  belongs_to :lab_hl7_receipt, optional: true
  belongs_to :reagent_lot, class_name: "LabSupplyLot", optional: true
  belongs_to :entered_by_user, class_name: "User", optional: true

  def inspect = "#<LabQcValue id=#{id} analyte_key=#{analyte_key} level=#{level} outcome=#{outcome}>"
end
