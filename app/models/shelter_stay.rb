# Estada no canil ou gatil (módulo 35b, ADR 0054; contrato §1 e §7): uma
# aberta por animal (único parcial); só a saída muda, uma vez (trigger). O
# animal e o adotante nunca saem em inspect, to_s, pretty_print nem as_json —
# só o id e se está aberta.
class ShelterStay < ApplicationRecord
  belongs_to :animal
  belongs_to :health_unit
  belongs_to :adopter_patient, class_name: "Patient", optional: true
  belongs_to :bite_observation, optional: true, inverse_of: :shelter_stays

  scope :open_stays, -> { where(exited_on: nil) }

  def open? = exited_on.nil?

  def inspect = "#<ShelterStay id=#{id} open=#{open?}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "open" => open? }
end
