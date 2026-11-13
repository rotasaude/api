# Profissional que participou da atividade coletiva (módulo 24b, ADR 0052). Só
# acréscimo (trigger); não inclui quem registra (o cabeçalho). Sem dado pessoal
# em inspect/to_s/as_json.
class CollectiveActivityProfessional < ApplicationRecord
  belongs_to :collective_activity
  belongs_to :professional

  def inspect = "#<CollectiveActivityProfessional id=#{id}>"
  alias_method :to_s, :inspect
  def pretty_print(pp) = pp.text(inspect)

  def as_json(*) = { "id" => id }
end
