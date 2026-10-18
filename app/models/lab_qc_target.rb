# Referência (média e dp) por lote, nível, analito e aparelho, versionada e imutável (ADR 0038).
class LabQcTarget < ApplicationRecord
  SOURCES = %w[package_insert laboratory].freeze

  belongs_to :lab_qc_lot
  belongs_to :lab_instrument
  belongs_to :accepted_by_user, class_name: "User"

  def self.current(lot_id:, level:, analyte_key:, instrument_id:)
    where(lab_qc_lot_id: lot_id, level: level, analyte_key: analyte_key, lab_instrument_id: instrument_id).order(:version).last
  end
end
