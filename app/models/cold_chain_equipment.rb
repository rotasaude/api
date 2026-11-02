# Equipamento da cadeia de frio (geladeira, câmara, freezer) num local de
# vacina, com a faixa de temperatura aceita (ADR 0047). Nunca é apagado
# (trigger): desativa-se.
class ColdChainEquipment < ApplicationRecord
  # "equipment" é incontável no inflector do Rails.
  self.table_name = "cold_chain_equipments"

  belongs_to :stock_location
  has_many :readings, class_name: "ColdChainReading", inverse_of: :cold_chain_equipment

  scope :active_equipments, -> { where(active: true) }
end
