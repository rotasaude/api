# RAAS do mês de uma matrícula (ADR 0049): uma por matrícula e mês (dia 1º).
# Aberta lê ao vivo; fechada guarda a foto (snapshot, JSON cifrado com a chave
# da cidade); exportada congela (trigger). Dado do paciente nunca sai em
# inspect, to_s, pretty_print nem as_json — só o id.
class PsychosocialMonthlyRecord < ApplicationRecord
  serialize :snapshot, coder: JSON
  encrypts :snapshot

  belongs_to :psychosocial_enrollment
  belongs_to :health_unit
  belongs_to :psychosocial_raas_export, optional: true

  def inspect = "#<PsychosocialMonthlyRecord id=#{id} status=#{status}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
