# Encaminhamento por extrato (ADR 0051): a um setor ou a uma unidade (CHECK:
# um). Extrato, destino e criação imutáveis; sai de pending uma vez (resposta,
# recusa — com o motivo em reply, Q9 — ou cancelamento) e então congela;
# prorroga uma vez com prazo e motivo juntos (trigger). Extrato, resposta e
# motivo cifrados; nunca saem em inspect, to_s, pretty_print nem as_json.
class OmbudsmanForwarding < ApplicationRecord
  encrypts :extract
  encrypts :extension_reason
  encrypts :reply

  belongs_to :ombudsman_manifestation
  belongs_to :department, optional: true
  belongs_to :health_unit, optional: true
  belongs_to :replied_by_user, class_name: "User", optional: true
  belongs_to :created_by_user, class_name: "User"

  def destination = department || health_unit
  def pending? = state == "pending"

  def inspect = "#<OmbudsmanForwarding id=#{id} state=#{state}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id, "state" => state }
end
