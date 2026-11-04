# Encaminhamento da UBS ao CAPS (ADR 0049): o motivo é cifrado com a chave da
# cidade; a exclusão LGPD o anonimiza (anonymized_at). Nunca é apagado
# (trigger). Dado do paciente nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class PsychosocialReferral < ApplicationRecord
  encrypts :reason

  belongs_to :patient
  belongs_to :health_unit
  belongs_to :from_health_unit, class_name: "HealthUnit"
  belongs_to :referred_by_user, class_name: "User"
  has_one :psychosocial_reception, inverse_of: :psychosocial_referral, dependent: :restrict_with_error

  def inspect = "#<PsychosocialReferral id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
