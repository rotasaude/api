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

  def inspect = "#<VialOpening id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
