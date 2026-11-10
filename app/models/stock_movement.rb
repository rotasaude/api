# Movimento de estoque (ADR 0045): só acréscimo (a re-cifra do motivo passa
# pela marca de CityEncryption). Quantidade com sinal pelo tipo; um documento
# por movimento (entrada, transferência, item de dispensação ou ajuste); o
# saldo (local, lote) nunca negativo (trigger). O motivo é cifrado e não sai
# em inspect, to_s, pretty_print nem as_json. Módulo 29 (ADR 0047, Desvio 7):
# abertura de frasco e dose de unidose (e a devolução dela) têm o frasco ou a
# dose por documento; o código do imunobiológico é cópia do lote (trigger).
class StockMovement < ApplicationRecord
  encrypts :reason

  belongs_to :stock_location
  belongs_to :stock_lot, inverse_of: :movements
  belongs_to :stock_entry, optional: true, inverse_of: :movements
  belongs_to :stock_transfer, optional: true
  belongs_to :dispensation_item, optional: true
  belongs_to :stock_adjustment, optional: true
  belongs_to :vial_opening, optional: true
  belongs_to :immunization, optional: true
  belongs_to :urgency_administration, optional: true
  belongs_to :recorded_by_user, class_name: "User"

  def inspect = "#<StockMovement id=#{id} kind=#{kind}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
