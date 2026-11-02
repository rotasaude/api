# Frasco multidose aberto na sala (ADR 0047, Desvio 8): vence em
# opened_at + validade após aberto do fabricante. Só fecha, uma vez (trigger):
# no descarte (autor e motivo cifrado) ou no vencimento (job), gravando a
# perda técnica. Nada do paciente nem o motivo em inspect, to_s, pretty_print
# nem as_json — só o id.
class VialOpening < ApplicationRecord
  encrypts :close_reason

  belongs_to :vaccine_room, inverse_of: :vial_openings
  belongs_to :stock_lot
  belongs_to :opened_by_user, class_name: "User"
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_many :immunizations, inverse_of: :vial_opening, dependent: :restrict_with_error

  scope :open_vials, -> { where(closed_at: nil) }

  # Doses de imunizações ativas (não canceladas) tiradas deste frasco.
  def doses_used = immunizations.active.count
  def doses_left = [ doses_per_vial - doses_used, 0 ].max

  # "closed_out": descartado por alguém; "expired": vencido (o job fecha sem
  # autor, mas até ele passar o vencimento já vale); senão "open".
  def status(now = Time.current)
    return "closed_out" if closed_by_user_id
    return "expired" if closed_at || expires_at <= now

    "open"
  end

  def inspect = "#<VialOpening id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
