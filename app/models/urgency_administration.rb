# Checagem de um horário da medicação na UPA (ADR 0050; contrato §5): só
# acréscimo; o motivo (não administrada ou recusada) é cifrado com a chave da
# cidade. Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyAdministration < ApplicationRecord
  encrypts :reason

  belongs_to :urgency_prescription_item, inverse_of: :administrations
  belongs_to :urgency_encounter
  belongs_to :stock_lot, optional: true
  belongs_to :recorded_by_user, class_name: "User"
  belongs_to :professional_link

  validates :status, inclusion: { in: Urgency::Catalog::ADMINISTRATION_STATUSES }

  def inspect = "#<UrgencyAdministration id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
