# Estoque mínimo de um item num local (ADR 0045): alimenta o alerta de abaixo
# do mínimo. Nunca é apagado (trigger): mínimo zero desliga o alerta.
class StockMinimum < ApplicationRecord
  belongs_to :stock_location
  belongs_to :updated_by_user, class_name: "User"
end
