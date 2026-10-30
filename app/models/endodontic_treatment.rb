# Tratamento endodôntico (ADR 0046): um em andamento por paciente e dente
# (índice parcial); muda só em andamento e, concluído, nunca muda; nunca some
# (trigger). Dado clínico fora de inspect, to_s, pretty_print e as_json.
class EndodonticTreatment < ApplicationRecord
  belongs_to :patient
  belongs_to :health_unit
  belongs_to :opened_in_consultation, class_name: "Consultation"
  belongs_to :completed_in_consultation, class_name: "Consultation", optional: true
  has_many :sessions, class_name: "EndodonticSession", inverse_of: :endodontic_treatment, dependent: :restrict_with_error

  def inspect = "#<EndodonticTreatment id=#{id} patient_id=#{patient_id} health_unit_id=#{health_unit_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
