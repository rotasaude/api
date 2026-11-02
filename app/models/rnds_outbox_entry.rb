# Uma entrada na fila de envio à RNDS (ADR 0047, Desvio 12): uma por dose
# (application) e por cancelamento (cancellation), índice único. O payload é o
# Bundle RIA-R cifrado com a chave da cidade e vai a nulo no aceite (CHECK).
# Nunca é apagada (trigger). Nada do paciente em inspect, to_s, pretty_print
# nem as_json — só o id.
class RndsOutboxEntry < ApplicationRecord
  self.table_name = "rnds_outbox"

  encrypts :payload

  belongs_to :immunization, inverse_of: :rnds_outbox_entries

  def inspect = "#<RndsOutboxEntry id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
