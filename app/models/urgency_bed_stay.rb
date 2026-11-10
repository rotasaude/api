# Estadia do encontro num leito da observação (ADR 0050; contrato §1 e §11):
# nasce aberta, só com o encontro em atendimento; um ocupante por leito
# (exclusion) e uma estadia aberta por encontro (índice). Fechada, nunca muda
# (trigger). Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyBedStay < ApplicationRecord
  belongs_to :urgency_encounter, inverse_of: :bed_stays
  belongs_to :urgency_bed, inverse_of: :bed_stays
  belongs_to :health_unit
  belongs_to :started_by_user, class_name: "User"
  belongs_to :ended_by_user, class_name: "User", optional: true

  scope :open_stays, -> { where(ended_at: nil) }

  def open? = ended_at.nil?

  def inspect = "#<UrgencyBedStay id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
