# Item de transferência (ADR 0045): um lote, o enviado e, no recebimento (uma
# vez, trigger), o recebido e o motivo da diferença. O motivo é cifrado e não
# sai em inspect, to_s, pretty_print nem as_json.
class StockTransferItem < ApplicationRecord
  encrypts :difference_reason

  belongs_to :stock_transfer, inverse_of: :items
  belongs_to :stock_lot

  def inspect = "#<StockTransferItem id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
