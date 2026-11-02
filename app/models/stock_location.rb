# Local de estoque (ADR 0045): o almoxarifado central (um só na cidade) ou a
# farmácia de uma unidade (health_units.dispenses). Módulo 29 (ADR 0047,
# Desvio 4): também a rede de frio municipal (cold_chain_central, uma só) e a
# sala de vacina (vaccine_room, uma por unidade, ao lado da farmácia). Nunca é
# apagado (trigger): desativa-se. Tipo, unidade e unicidade são do banco; a
# validação com mensagem é dos comandos.
class StockLocation < ApplicationRecord
  belongs_to :health_unit, optional: true
  belongs_to :updated_by_user, class_name: "User"
  has_many :staff, class_name: "StockLocationStaff", inverse_of: :stock_location

  scope :active_locations, -> { where(active: true) }

  def central? = kind == "central"
  def unit? = kind == "unit"
  def cold_chain_central? = kind == "cold_chain_central"
  def vaccine_room? = kind == "vaccine_room"
end
