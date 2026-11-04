# Participante de uma ação do CAPS (ADR 0049): paciente (matriculado ou não)
# ou familiar sem cadastro (nome cifrado com a chave da cidade) — um dos dois
# (CHECK). Só acréscimo (trigger). Dado do paciente nunca sai em inspect, to_s,
# pretty_print nem as_json — só o id.
class PsychosocialActionParticipant < ApplicationRecord
  encrypts :family_name

  belongs_to :psychosocial_action
  belongs_to :psychosocial_enrollment, optional: true
  belongs_to :patient, optional: true

  def inspect = "#<PsychosocialActionParticipant id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
