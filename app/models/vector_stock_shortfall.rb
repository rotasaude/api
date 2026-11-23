# Falta de estoque da baixa (módulo 35a; contrato §4; W-6, W-7; módulo 35b, Q17):
# sem local, sem saldo num lote válido ou sem lote. Nunca recusa o registro. Tem
# origem (`source`: a medida do boletim, a dose antirrábica ou a coleira, com a
# referência exata dela) e o dia (`occurred_on`: o da visita, da dose ou da
# coleira). Aberta até a conciliação (uma vez): pela coordenação ou pelo
# estoquista, com usuário e nota (cifrada); pelo sistema no estorno, sem nenhum
# dos dois. Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class VectorStockShortfall < ApplicationRecord
  CAUSES = %w[no_location insufficient_balance no_lot].freeze
  SOURCES = %w[inspection vaccination collar].freeze

  encrypts :reconciliation_note

  # As faltas do boletim (35a) não dizem a origem: é a inspeção.
  attribute :source, :string, default: "inspection"

  belongs_to :vector_inspection_measure, optional: true, inverse_of: :shortfall
  belongs_to :rabies_vaccination, optional: true, inverse_of: :shortfall
  belongs_to :collar, optional: true, inverse_of: :shortfall
  belongs_to :stock_location, optional: true
  belongs_to :vector_product
  belongs_to :reconciled_by_user, class_name: "User", optional: true

  validates :cause, inclusion: { in: CAUSES }
  validates :source, inclusion: { in: SOURCES }

  # A da inspeção sem o dia dado leva o dia da visita.
  before_create { self.occurred_on ||= visit_day if source == "inspection" }

  scope :open_shortfalls, -> { where(reconciled_at: nil) }

  def inspect = "#<VectorStockShortfall id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }

  private

  def visit_day = vector_inspection_measure&.vector_inspection&.home_visit&.occurred_at&.in_time_zone&.to_date
end
