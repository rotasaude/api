# Demanda de zoonoses da ouvidoria (módulo 35b, ADR 0054; contrato §1 e §4):
# 1:1 com o encaminhamento do 33. O estado só anda para a frente (trigger). A
# nota da inspeção é cifrada com a chave da cidade. Nunca sai em inspect,
# to_s, pretty_print nem as_json além do id e do estado.
class ZoonosesDemand < ApplicationRecord
  encrypts :inspection_note

  belongs_to :ombudsman_forwarding
  belongs_to :assigned_user, class_name: "User", optional: true

  def inspect = "#<ZoonosesDemand id=#{id} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "state" => state }
end
