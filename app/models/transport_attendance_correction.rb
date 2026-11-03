# Correção da presença depois do fechamento (ADR 0048, Desvio 9): uma linha
# por campo mudado, com o motivo cifrado com a chave da cidade. Imutável
# (trigger; a re-cifra regrava só o motivo).
class TransportAttendanceCorrection < ApplicationRecord
  encrypts :reason

  belongs_to :transport_trip_passenger, inverse_of: :transport_attendance_corrections
  belongs_to :by_user, class_name: "User"

  def inspect = "#<TransportAttendanceCorrection id=#{id} field=#{field}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
