# Entrada de estoque num local (ADR 0045): nota, doação ou inventário de
# abertura. Só acréscimo (trigger); os itens são os movimentos dela.
class StockEntry < ApplicationRecord
  belongs_to :stock_location
  belongs_to :recorded_by_user, class_name: "User"
  has_many :movements, class_name: "StockMovement", inverse_of: :stock_entry
end
