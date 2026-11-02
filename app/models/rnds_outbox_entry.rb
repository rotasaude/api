# Uma entrada na fila de envio à RNDS (ADR 0047, Desvio 12): uma por dose
# (application) e por cancelamento (cancellation), índice único. O payload é o
# Bundle RIA-R cifrado com a chave da cidade e vai a nulo no aceite (CHECK).
# Nunca é apagada (trigger). Nada do paciente em inspect, to_s, pretty_print
# nem as_json — só o id.
class RndsOutboxEntry < ApplicationRecord
  self.table_name = "rnds_outbox"

  encrypts :payload

  belongs_to :immunization, inverse_of: :rnds_outbox_entries

  # Situações em que a entrada já foi (ou pode ter sido) enviada à RNDS.
  # `pending` com `first_attempt_at` também conta: um timeout deixa o
  # resultado desconhecido. `blocked` nunca saiu (a validação NT 115 vem antes
  # do envio).
  ATTEMPTED_STATUSES = %w[sending accepted rejected failed].freeze

  # `application` de dose CANCELADA que nunca foi tentada (`pending` sem
  # tentativa ou `blocked`): não vai à RNDS e não nasce `cancellation` para ela
  # (ruling do Fix round 1 da Task 9). Fica como está — a fila não se apaga e
  # não há status novo — e o claim da Task 13 a exclui com `not_withdrawn`.
  scope :withdrawn, lambda {
    joins(:immunization).where(kind: "application").where.not(immunizations: { cancelled_at: nil })
                        .where("rnds_outbox.status = 'blocked' OR (rnds_outbox.status = 'pending' AND rnds_outbox.first_attempt_at IS NULL)")
  }
  scope :not_withdrawn, -> { where.not(id: withdrawn.select(:id)) }

  def attempted? = ATTEMPTED_STATUSES.include?(status) || (status == "pending" && first_attempt_at.present?)

  def inspect = "#<RndsOutboxEntry id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
