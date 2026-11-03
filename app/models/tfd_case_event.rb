# Andamento do processo de TFD (ADR 0048): uma linha por mudança, com o
# motivo cifrado com a chave da cidade. Só acréscimo (trigger; a re-cifra
# regrava só o motivo).
class TfdCaseEvent < ApplicationRecord
  encrypts :reason

  belongs_to :tfd_case, inverse_of: :tfd_case_events
  belongs_to :by_user, class_name: "User", optional: true

  def inspect = "#<TfdCaseEvent id=#{id} kind=#{kind}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
