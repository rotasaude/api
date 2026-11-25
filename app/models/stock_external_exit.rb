# Saída externa do estoque (módulo 27b; contrato §4): devolução ao fornecedor,
# remanejamento a outro ente, doação ou empréstimo (S-DF, S-TR, S-D, S-E), com o
# destino (CNES ou CNPJ). Nunca some; a correção (tipo, destino e motivo, com
# version + 1) vale para a saída inteira (Q8). O motivo é cifrado e não sai em
# inspect, to_s, pretty_print nem as_json.
class StockExternalExit < ApplicationRecord
  encrypts :reason

  belongs_to :stock_location
  belongs_to :recorded_by_user, class_name: "User"
  has_many :items, class_name: "StockExternalExitItem", inverse_of: :stock_external_exit
  has_many :movements, class_name: "StockMovement", inverse_of: :stock_external_exit

  def inspect = "#<StockExternalExit id=#{id} exit_type=#{exit_type} version=#{version}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
