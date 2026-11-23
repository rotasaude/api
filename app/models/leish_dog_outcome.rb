# Desfecho do cão reagente (módulo 35b, ADR 0054; contrato §1 e §6, Q18): só
# acréscimo (trigger); decision euthanasia ⇔ euthanasia_id (CHECK). A nota é
# cifrada com a chave da cidade. Nunca sai em inspect, to_s, pretty_print nem
# as_json além do id e da decisão.
class LeishDogOutcome < ApplicationRecord
  encrypts :note

  belongs_to :animal
  belongs_to :leish_test, inverse_of: :outcome
  belongs_to :euthanasia, optional: true

  def inspect = "#<LeishDogOutcome id=#{id} decision=#{decision}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "decision" => decision }
end
