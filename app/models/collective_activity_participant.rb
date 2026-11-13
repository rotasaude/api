# Participante da atividade coletiva (módulo 24b, ADR 0052). Só acréscimo
# (trigger; a re-cifra regrava só as colunas cifradas). Avaliação alterada,
# medidas e tabagismo são cifrados com a chave da cidade (`serialize` ANTES de
# `encrypts`). Sem dado pessoal em inspect/to_s/as_json.
class CollectiveActivityParticipant < ApplicationRecord
  belongs_to :collective_activity
  belongs_to :patient

  serialize :altered_evaluation, coder: JSON
  serialize :measurements, coder: JSON
  serialize :smoking, coder: JSON
  encrypts :altered_evaluation, :measurements, :smoking

  def inspect = "#<CollectiveActivityParticipant id=#{id}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)

  def as_json(*) = { "id" => id }
end
