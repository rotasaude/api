# Marca do inventário de abertura de um item num local (ADR 0045): uma vez
# por (local, item), índice único. Só acréscimo (trigger).
class StockOpening < ApplicationRecord
  belongs_to :stock_location
  belongs_to :stock_entry
end
