# Item da prescrição da UPA (ADR 0050; contrato §5): só acréscimo; as
# instruções são cifradas com a chave da cidade. `controlled_list` é a cópia da
# lista do catálogo no dia da prescrição (§12 Q4). Nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class UrgencyPrescriptionItem < ApplicationRecord
  encrypts :instructions

  belongs_to :urgency_prescription, inverse_of: :items
  has_many :administrations, class_name: "UrgencyAdministration", foreign_key: :urgency_prescription_item_id,
                             inverse_of: :urgency_prescription_item, dependent: :restrict_with_error

  def controlled? = controlled_list.present?

  def inspect = "#<UrgencyPrescriptionItem id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
