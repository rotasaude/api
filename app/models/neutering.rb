# Castração (módulo 35b, ADR 0054; contrato §1 e §7): só acréscimo (trigger),
# uma por animal. Nunca sai em inspect, to_s, pretty_print nem as_json além
# do id.
class Neutering < ApplicationRecord
  belongs_to :animal
  belongs_to :professional
  belongs_to :shelter_stay, optional: true

  def inspect = "#<Neutering id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
