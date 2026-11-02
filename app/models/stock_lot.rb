# Lote de um item do catálogo CATMAT (ADR 0045): número único por item na
# cidade, validade e a unidade de dispensação gravada na primeira entrada
# (Desvio 1). Só acréscimo (trigger). O saldo é por local: a soma dos
# movimentos (local, lote). Módulo 29 (ADR 0047, Desvio 3): o lote de
# imunobiológico (item_kind) não tem CATMAT, tem o código do imunobiológico e
# o fabricante (código RNDS, pode ser nulo), sempre em doses (CHECK).
class StockLot < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"
  has_many :movements, class_name: "StockMovement", inverse_of: :stock_lot
  has_many :blocks, class_name: "StockLotBlock", inverse_of: :stock_lot

  def immunobiological? = item_kind == "immunobiological"

  def expired?(today = Time.zone.today) = expires_on < today
end
