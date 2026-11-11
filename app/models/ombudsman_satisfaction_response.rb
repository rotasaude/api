# Pesquisa de satisfação (ADR 0051; contrato §10): uma por manifestação, só
# acréscimo (trigger). Fica na exclusão LGPD (não tem o cidadão). Nunca sai em
# inspect, to_s, pretty_print nem as_json.
class OmbudsmanSatisfactionResponse < ApplicationRecord
  belongs_to :ombudsman_manifestation

  def inspect = "#<OmbudsmanSatisfactionResponse id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
