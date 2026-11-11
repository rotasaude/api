# Linha do tempo da manifestação (ADR 0051; plano, Desvio 5): só acréscimo
# (trigger; a re-cifra regrava o texto). `data` leva só ids, rótulos de
# catálogo e estado anterior/novo; `visible_to_citizen` decide o que o cidadão
# vê. Texto cifrado; nunca sai em inspect, to_s, pretty_print nem as_json.
class OmbudsmanEvent < ApplicationRecord
  ACTORS = %w[staff citizen system].freeze

  encrypts :text

  belongs_to :ombudsman_manifestation
  belongs_to :actor_user, class_name: "User", optional: true

  def inspect = "#<OmbudsmanEvent id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
