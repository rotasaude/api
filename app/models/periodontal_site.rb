# Sítio do periograma (ADR 0046): sondagem, recessão e sangramento. Só
# acréscimo (trigger). Dado clínico fora de inspect, to_s, pretty_print e
# as_json.
class PeriodontalSite < ApplicationRecord
  belongs_to :periodontal_chart, inverse_of: :sites

  def inspect = "#<PeriodontalSite id=#{id} periodontal_chart_id=#{periodontal_chart_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
