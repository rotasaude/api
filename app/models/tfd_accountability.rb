# Prestação de contas do TFD (ADR 0048, §14 T13): o comprovante (arquivo do
# Exams::Files, propósito tfd_accountability) com o nome cifrado com a chave
# da cidade; uma por processo, só acréscimo (trigger; a re-cifra regrava só o
# nome). Nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class TfdAccountability < ApplicationRecord
  self.table_name = "tfd_accountability"

  encrypts :filename

  belongs_to :tfd_case, inverse_of: :tfd_accountability
  belongs_to :exam_file
  belongs_to :closed_by_user, class_name: "User"

  def inspect = "#<TfdAccountability id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
