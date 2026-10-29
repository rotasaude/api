# Item da receita externa (ADR 0045): item do catálogo, quantidade, posologia
# cifrada, uso contínuo e o retrato da lista de controle. Só a re-cifra regrava
# (trigger). Nada clínico em inspect, to_s, pretty_print ou as_json.
class ExternalPrescriptionItem < ApplicationRecord
  encrypts :dosage_instructions

  belongs_to :external_prescription, inverse_of: :items

  def inspect = "#<ExternalPrescriptionItem id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
