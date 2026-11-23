# Coleira de deltametrina no cão (módulo 35b, ADR 0054; contrato §1 e §3). Uma
# ativa (sem removed_on) por animal; só a retirada muda, uma vez (trigger). A
# baixa do estoque leva a coleira como documento. Nunca sai em inspect, to_s,
# pretty_print nem as_json além do id.
class Collar < ApplicationRecord
  belongs_to :animal
  belongs_to :vector_product
  has_many :movements, class_name: "StockMovement", inverse_of: :collar, dependent: :restrict_with_error
  has_one :shortfall, class_name: "VectorStockShortfall", inverse_of: :collar, dependent: :restrict_with_error

  scope :active, -> { where(removed_on: nil) }

  def removed? = removed_on.present?

  def inspect = "#<Collar id=#{id} removed=#{removed?}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "removed" => removed? }
end
