# Movimento de estoque (ADR 0038): só acréscimo; quantidade com sinal (entrada +, saída −).
class LabSupplyMovement < ApplicationRecord
  KINDS = %w[receipt opening loss expiry adjustment].freeze

  belongs_to :lab_supply_lot
  belongs_to :recorded_by_user, class_name: "User"
end
