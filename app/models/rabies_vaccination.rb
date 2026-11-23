# Dose de vacina antirrábica em cão ou gato (módulo 35b, ADR 0054; contrato §1
# e §3). Imutável (trigger): só a anulação muda, uma vez (cancelled_at e
# cancel_reason), e estorna a baixa do estoque. A nota do evento adverso e o
# motivo da anulação são cifrados com a chave da cidade. Animal e domicílio
# nunca saem em inspect, to_s, pretty_print nem as_json — só o id.
class RabiesVaccination < ApplicationRecord
  encrypts :adverse_note, :cancel_reason

  belongs_to :animal, optional: true
  belongs_to :campaign, class_name: "RabiesCampaign", optional: true, inverse_of: :vaccinations
  belongs_to :health_unit, optional: true
  belongs_to :household, optional: true
  belongs_to :vector_product
  belongs_to :stock_lot, optional: true
  belongs_to :recorded_by_user, class_name: "User"
  has_many :movements, class_name: "StockMovement", inverse_of: :rabies_vaccination, dependent: :restrict_with_error
  has_one :shortfall, class_name: "VectorStockShortfall", inverse_of: :rabies_vaccination, dependent: :restrict_with_error

  scope :active, -> { where(cancelled_at: nil) }

  def cancelled? = cancelled_at.present?

  def inspect = "#<RabiesVaccination id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
