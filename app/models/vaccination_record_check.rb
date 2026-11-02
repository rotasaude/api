# Conferência da caderneta de vacinação (ADR 0047, Desvio 10): sem ela,
# nenhum item fica em atraso. Imutável (trigger). born_after_go_live é gravada
# pelo sistema (sem autor nem sala). Nada do paciente em inspect, to_s,
# pretty_print nem as_json — só o id.
class VaccinationRecordCheck < ApplicationRecord
  belongs_to :patient
  belongs_to :vaccine_room, optional: true
  belongs_to :checked_by_user, class_name: "User", optional: true

  def inspect = "#<VaccinationRecordCheck id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
