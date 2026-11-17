# Falta de estoque da baixa do boletim (módulo 35a; contrato §4; W-6, W-7): sem
# local, sem saldo num lote válido ou sem lote. Nunca recusa a visita. Aberta
# até a conciliação (uma vez): pela coordenação ou pelo estoquista, com
# usuário e nota (cifrada); pelo sistema no estorno, sem nenhum dos dois.
# Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class VectorStockShortfall < ApplicationRecord
  CAUSES = %w[no_location insufficient_balance no_lot].freeze

  encrypts :reconciliation_note

  belongs_to :vector_inspection_measure, inverse_of: :shortfall
  belongs_to :stock_location, optional: true
  belongs_to :vector_product
  belongs_to :reconciled_by_user, class_name: "User", optional: true

  validates :cause, inclusion: { in: CAUSES }

  scope :open_shortfalls, -> { where(reconciled_at: nil) }

  def inspect = "#<VectorStockShortfall id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
