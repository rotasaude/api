# Situação vacinal materializada por paciente e série (ADR 0047, Desvio 11):
# cópia recalculável (DELETE + INSERT por paciente), lida pelos critérios de
# campanha e pelo painel. A fonte da verdade são as doses e o calendário. Nada
# do paciente em inspect, to_s, pretty_print nem as_json — só o id.
class VaccinationStatus < ApplicationRecord
  belongs_to :patient

  def inspect = "#<VaccinationStatus id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
