# Local de estoque (ADR 0045): o almoxarifado central (um só na cidade) ou a
# farmácia de uma unidade (health_units.dispenses). Nunca é apagado (trigger):
# desativa-se. Tipo, unidade e unicidade são do banco; a validação com
# mensagem é dos comandos.
class StockLocation < ApplicationRecord
  belongs_to :health_unit, optional: true
  belongs_to :updated_by_user, class_name: "User"
  has_many :staff, class_name: "StockLocationStaff", inverse_of: :stock_location

  scope :active_locations, -> { where(active: true) }

  def central? = kind == "central"
  def unit? = kind == "unit"
end
