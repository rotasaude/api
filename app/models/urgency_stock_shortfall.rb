# Falta de estoque da checagem da UPA (ADR 0050; contrato §6; R7): a baixa não
# pôde acontecer (sem local, saldo insuficiente, lote indisponível). Aberta até
# a conciliação (uma vez); a nota é cifrada com a chave da cidade. Nunca sai em
# inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyStockShortfall < ApplicationRecord
  encrypts :reconciliation_note

  belongs_to :urgency_administration
  belongs_to :stock_location, optional: true
  belongs_to :reconciled_by_user, class_name: "User", optional: true

  validates :cause, inclusion: { in: Urgency::Catalog::SHORTFALL_CAUSES }

  scope :open_shortfalls, -> { where(reconciled_at: nil) }

  def inspect = "#<UrgencyStockShortfall id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
