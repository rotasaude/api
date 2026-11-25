# Lote e quantidade inteira de uma saída externa (módulo 27b). Só acréscimo.
class StockExternalExitItem < ApplicationRecord
  belongs_to :stock_external_exit, inverse_of: :items
  belongs_to :stock_lot
end
