# Item dispensado (ADR 0045): o item da receita (19c ou externa), o item do
# catálogo, o lote e a quantidade; o movimento dispensing aponta para cá. Só
# acréscimo (trigger). Nada clínico em inspect, to_s, pretty_print ou as_json.
class DispensationItem < ApplicationRecord
  belongs_to :dispensation, inverse_of: :items
  belongs_to :prescription_item, optional: true
  belongs_to :external_prescription_item, optional: true
  belongs_to :stock_lot
  has_many :movements, class_name: "StockMovement", inverse_of: :dispensation_item

  def inspect = "#<DispensationItem id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
