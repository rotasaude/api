# Sessão de endodontia numa consulta (ADR 0046). Só acréscimo (trigger). Dado
# clínico fora de inspect, to_s, pretty_print e as_json.
class EndodonticSession < ApplicationRecord
  belongs_to :endodontic_treatment, inverse_of: :sessions
  belongs_to :consultation

  def inspect = "#<EndodonticSession id=#{id} endodontic_treatment_id=#{endodontic_treatment_id} consultation_id=#{consultation_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
