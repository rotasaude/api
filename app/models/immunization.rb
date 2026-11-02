# Dose de vacina aplicada na sala ou transcrita da caderneta (ADR 0047,
# Desvio 9). Imutável (trigger): só o cancelamento muda, uma vez
# (cancelled_at, cancelled_by_user_id, cancel_reason); a substituta aponta a
# original por replaces_id. A transcrição não tem lote do estoque (lote,
# fabricante e local em texto). Lote/fabricante/local da transcrição, a
# justificativa do aviso (§15 V5) e o motivo do cancelamento são cifrados com
# a chave da cidade. Vacina, lote e dose do paciente nunca saem em inspect,
# to_s, pretty_print nem as_json — só o id.
class Immunization < ApplicationRecord
  encrypts :lot_number_text, :manufacturer_text, :place_text, :override_reason, :cancel_reason

  belongs_to :patient
  belongs_to :vaccine_room, optional: true, inverse_of: :immunizations
  belongs_to :health_unit
  belongs_to :vaccinator_user, class_name: "User"
  belongs_to :stock_lot, optional: true
  belongs_to :vial_opening, optional: true, inverse_of: :immunizations
  belongs_to :campaign, optional: true
  belongs_to :replaces, class_name: "Immunization", optional: true, inverse_of: :replacement
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  has_one :replacement, class_name: "Immunization", foreign_key: :replaces_id, inverse_of: :replaces, dependent: :restrict_with_error
  has_many :rnds_outbox_entries, class_name: "RndsOutboxEntry", inverse_of: :immunization, dependent: :restrict_with_error

  scope :active, -> { where(cancelled_at: nil) }

  def cancelled? = cancelled_at.present?

  def inspect = "#<Immunization id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
