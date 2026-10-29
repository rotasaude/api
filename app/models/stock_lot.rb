# Lote de um item do catálogo CATMAT (ADR 0045): número único por item na
# cidade, validade e a unidade de dispensação gravada na primeira entrada
# (Desvio 1). Só acréscimo (trigger). O saldo é por local: a soma dos
# movimentos (local, lote).
class StockLot < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"
  has_many :movements, class_name: "StockMovement", inverse_of: :stock_lot

  def expired?(today = Time.zone.today) = expires_on < today
end
