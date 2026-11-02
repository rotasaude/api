# Bloqueio de um lote num local pela excursão de temperatura (ADR 0047): o
# lote não dá dose, não abre frasco, não é transferido nem ajustado enquanto
# aberto; a conduta (use | discard) o libera. Nunca é apagado (trigger).
# Task 14: guarda quem decidiu e o motivo (cifrado) e, no descarte, o ajuste de
# perda do 27a: pendente acima do limite, o bloqueio só cai quando ele for
# aprovado (Vaccination::ExcursionRelease). O motivo fica fora de inspect,
# to_s, pretty_print e as_json.
class StockLotBlock < ApplicationRecord
  encrypts :decision_reason

  belongs_to :stock_location
  belongs_to :stock_lot
  belongs_to :cold_chain_excursion, inverse_of: :stock_lot_blocks
  belongs_to :decided_by_user, class_name: "User", optional: true
  belongs_to :stock_adjustment, optional: true

  scope :open_blocks, -> { where(released_at: nil) }

  def inspect = "#<StockLotBlock id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
