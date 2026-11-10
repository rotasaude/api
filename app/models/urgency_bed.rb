# Leito da observação de uma UPA (ADR 0050; contrato §1): rótulo único na
# unidade; desativado sai do mapa. Só em unidade `upa` e nunca é apagado
# (trigger). Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyBed < ApplicationRecord
  belongs_to :health_unit
  belongs_to :updated_by_user, class_name: "User"
  has_many :bed_stays, class_name: "UrgencyBedStay", inverse_of: :urgency_bed, dependent: :restrict_with_error

  scope :active_beds, -> { where(active: true) }

  def inspect = "#<UrgencyBed id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
