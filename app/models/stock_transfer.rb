# Transferência do central para uma farmácia de unidade (ADR 0045): enviada
# (sent) e recebida uma vez (trigger). "Em trânsito" é derivado dos itens de
# transferências sent.
class StockTransfer < ApplicationRecord
  belongs_to :from_location, class_name: "StockLocation"
  belongs_to :to_location, class_name: "StockLocation"
  belongs_to :sent_by_user, class_name: "User"
  belongs_to :received_by_user, class_name: "User", optional: true
  has_many :items, class_name: "StockTransferItem", inverse_of: :stock_transfer
end
