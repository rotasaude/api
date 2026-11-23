# Eutanásia (módulo 35b, ADR 0054; contrato §1 e §7, invariante): só
# acréscimo e imutável (trigger, salvo a re-cifra), uma por animal; nota do
# motivo obrigatória e cifrada com a chave da cidade; ao menos uma base legal
# da lista (CHECK). A ligação com o desfecho da leishmaniose vai do desfecho
# para cá (Q18). Nunca sai em inspect, to_s, pretty_print nem as_json além do
# id.
class Euthanasia < ApplicationRecord
  self.table_name = "euthanasias"

  encrypts :reason_note

  belongs_to :animal
  belongs_to :professional
  belongs_to :shelter_stay, optional: true
  belongs_to :bite_observation, optional: true, inverse_of: :euthanasias

  def inspect = "#<Euthanasia id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
