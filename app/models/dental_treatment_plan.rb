# Plano de tratamento odontológico (ADR 0046; Desvio 7): no máximo um `open`
# por paciente e unidade (índice parcial). Fecha uma vez, de `open`
# (`completed` ou `cancelled`, com motivo cifrado); nunca some (trigger). Dado
# clínico fora de inspect, to_s, pretty_print e as_json.
class DentalTreatmentPlan < ApplicationRecord
  encrypts :cancel_reason

  belongs_to :patient
  belongs_to :health_unit
  belongs_to :opened_in_consultation, class_name: "Consultation"
  belongs_to :closed_in_consultation, class_name: "Consultation", optional: true
  belongs_to :closed_by_user, class_name: "User", optional: true
  has_many :items, class_name: "DentalTreatmentPlanItem", inverse_of: :dental_treatment_plan, dependent: :restrict_with_error

  scope :open_plans, -> { where(status: "open") }

  def inspect = "#<DentalTreatmentPlan id=#{id} patient_id=#{patient_id} health_unit_id=#{health_unit_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
