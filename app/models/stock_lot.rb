# Lote de um item do catálogo CATMAT (ADR 0045): número único por item na
# cidade, validade e a unidade de dispensação gravada na primeira entrada
# (Desvio 1). Só acréscimo (trigger). O saldo é por local: a soma dos
# movimentos (local, lote). Módulo 29 (ADR 0047, Desvio 3): o lote de
# imunobiológico (item_kind) não tem CATMAT, tem o código do imunobiológico e
# o fabricante pela `key` estável do catálogo (§15 V19: nunca o código RNDS;
# pode ser nulo), sempre em doses (CHECK). Módulo 35a (ADR 0054; contrato §4):
# o lote vector_control só tem o produto da vigilância ambiental (sem CATMAT,
# imunobiológico nem fabricante; CHECK); a unidade de dispensação é a do
# produto, conferida no comando.
class StockLot < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"
  belongs_to :vector_product, optional: true, inverse_of: :stock_lots
  has_many :movements, class_name: "StockMovement", inverse_of: :stock_lot
  has_many :blocks, class_name: "StockLotBlock", inverse_of: :stock_lot

  def immunobiological? = item_kind == "immunobiological"
  def vector_control? = item_kind == "vector_control"

  def expired?(today = Time.zone.today) = expires_on < today
end
