# Lote de um item (ADR 0038): só acréscimo; saldo = soma dos movimentos (nunca negativo).
class LabSupplyLot < ApplicationRecord
  ORIGINS = %w[purchase donation loan].freeze

  belongs_to :lab_supply
  belongs_to :created_by_user, class_name: "User"
  has_many :movements, -> { order(:recorded_at, :created_at) }, class_name: "LabSupplyMovement", inverse_of: :lab_supply_lot

  def balance = movements.sum(:quantity)
  def expired?(on = Time.current.in_time_zone.to_date) = expires_on < on
end
