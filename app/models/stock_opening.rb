# Marca do inventário de abertura de um item num local (ADR 0045): uma vez
# por (local, item), índice único parcial das ativas. Só acréscimo (trigger),
# salvo `reverted_at`, marcado uma vez ao desfazer a abertura (módulo 27b, Q10).
class StockOpening < ApplicationRecord
  # A abertura que vale: a revertida libera o (local, item) para abrir de novo.
  scope :active, -> { where(reverted_at: nil) }

  belongs_to :stock_location
  belongs_to :stock_entry
end
