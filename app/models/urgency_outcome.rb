# Desfecho da urgência (ADR 0050; contrato §7; plano, Desvio 13): um por
# encontro, imutável (trigger). Destino da transferência, pedido de vaga e
# motivo do retorno à UBS cifrados com a chave da cidade. Dado do paciente
# nunca sai em inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyOutcome < ApplicationRecord
  encrypts :destination, :vacancy_request, :return_reason

  belongs_to :urgency_encounter
  belongs_to :counter_referral_health_team, class_name: "HealthTeam", optional: true
  belongs_to :counter_referral_health_unit, class_name: "HealthUnit", optional: true
  belongs_to :recorded_by_user, class_name: "User"

  def inspect = "#<UrgencyOutcome id=#{id} kind=#{kind}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
