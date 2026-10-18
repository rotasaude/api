# Lote do material de controle (ADR 0038): só encerra (trigger).
class LabQcLot < ApplicationRecord
  STATUSES = %w[in_use closed].freeze

  belongs_to :lab_qc_material
  belongs_to :created_by_user, class_name: "User", optional: true
  has_many :barcodes, -> { order(:level) }, class_name: "LabQcLotBarcode", inverse_of: :lab_qc_lot

  def level_barcodes = barcodes.to_h { |b| [ b.level, b.barcode ] }
  def expired?(on = Time.current.in_time_zone.to_date) = expires_on < on
end
