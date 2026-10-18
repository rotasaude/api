# Lote de reagente em uso no par aparelho × exame (ADR 0038): um corrente por par; só termina.
class LabSupplyInUse < ApplicationRecord
  self.table_name = "lab_supply_in_use"

  belongs_to :lab_supply_lot
  belongs_to :lab_instrument
  belongs_to :lab_exam
  belongs_to :started_by_user, class_name: "User"
  belongs_to :ended_by_user, class_name: "User", optional: true

  scope :current, -> { where(ended_at: nil) }

  # Lido sem interruptor (Desvio 9): nil quando o exame não tem aparelho ou o par não tem lote em uso.
  def self.current_lot_id(instrument_id:, lab_exam_id:)
    return nil if instrument_id.nil? || lab_exam_id.nil?

    current.where(lab_instrument_id: instrument_id, lab_exam_id: lab_exam_id).pick(:lab_supply_lot_id)
  end
end
