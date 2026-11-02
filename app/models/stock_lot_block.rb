# Bloqueio de um lote num local pela excursão de temperatura (ADR 0047): o
# lote não dá dose, não abre frasco, não é transferido nem ajustado enquanto
# aberto; a conduta (use | discard) o libera. Nunca é apagado (trigger).
class StockLotBlock < ApplicationRecord
  belongs_to :stock_location
  belongs_to :stock_lot
  belongs_to :cold_chain_excursion, inverse_of: :stock_lot_blocks

  scope :open_blocks, -> { where(released_at: nil) }
end
