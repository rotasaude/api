# Caso compartilhado no matriciamento (ADR 0049): o texto que a UBS vê do
# vínculo do paciente com o CAPS (cifrado com a chave da cidade). Só acréscimo
# (trigger). Dado do paciente nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class PsychosocialMatrixCase < ApplicationRecord
  encrypts :shared_text

  belongs_to :psychosocial_matrix_support
  belongs_to :patient
  belongs_to :created_by_user, class_name: "User"

  def inspect = "#<PsychosocialMatrixCase id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
