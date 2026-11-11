# Aviso ao cidadão (ADR 0051; contrato §3/§9): sem texto, só o tipo; só
# read_at muda, uma vez (trigger, padrão de transport_trip_notices). Apagado na
# exclusão LGPD. Nunca sai em inspect, to_s, pretty_print nem as_json.
class OmbudsmanNotice < ApplicationRecord
  belongs_to :citizen
  belongs_to :ombudsman_manifestation

  def inspect = "#<OmbudsmanNotice id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
