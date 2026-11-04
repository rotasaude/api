# Acolhimento no CAPS (ADR 0049), com ou sem encaminhamento: o registro é
# cifrado com a chave da cidade; a exclusão LGPD o anonimiza. Nunca é apagado
# (trigger). Dado do paciente nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class PsychosocialReception < ApplicationRecord
  encrypts :notes

  belongs_to :health_unit
  belongs_to :patient
  belongs_to :psychosocial_referral, optional: true
  belongs_to :recorded_by_user, class_name: "User"

  def inspect = "#<PsychosocialReception id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
