# Item de estoque do laboratório (ADR 0038): reagente tem rendimento em testes.
class LabSupply < ApplicationRecord
  KINDS = %w[reagent calibrator control consumable].freeze

  belongs_to :exam_provider
  has_many :lots, -> { order(:expires_on, :lot_number) }, class_name: "LabSupplyLot", inverse_of: :lab_supply
end
