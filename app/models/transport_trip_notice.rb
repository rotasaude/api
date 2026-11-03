# Aviso de viagem ao cidadão (ADR 0048, Desvio 8): um por (passageiro, par,
# tipo, chave do evento), com a saída e o rótulo da parada do momento (o último
# valor avisado, Ruling I-2). Só é lido, uma vez (trigger); a exclusão do par o
# apaga. Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class TransportTripNotice < ApplicationRecord
  belongs_to :transport_trip_passenger, inverse_of: :transport_trip_notices
  belongs_to :citizen

  def inspect = "#<TransportTripNotice id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
