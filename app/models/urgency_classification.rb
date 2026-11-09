# Classificação de risco da urgência (ADR 0050; contrato §5 e §14 Q2, Q3,
# Q18): só acréscimo (trigger), numerada por encontro; reclassificar grava a
# seguinte. Guarda a foto do tempo máximo da cor e o protocolo da sugestão
# (trocar o protocolo não muda o estouro de quem já foi classificado). A dor
# fica fora dos sinais (`pain_scale`). Queixa, sinais (JSON), critério e
# justificativa cifrados com a chave da cidade. Dado do paciente nunca sai em
# inspect, to_s, pretty_print nem as_json — só o id.
class UrgencyClassification < ApplicationRecord
  serialize :vital_signs, coder: JSON
  encrypts :complaint, :vital_signs, :criterion, :justification

  belongs_to :urgency_encounter
  belongs_to :protocol_definition, optional: true
  belongs_to :classified_by_user, class_name: "User"
  belongs_to :professional_link

  def inspect = "#<UrgencyClassification id=#{id} position=#{position}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
