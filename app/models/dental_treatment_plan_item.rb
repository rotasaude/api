# Item do plano de tratamento (ADR 0046): procedimento previsto num local.
# Muda uma vez, de `planned` (`done` pela consulta que o fez, ou `cancelled`
# com motivo cifrado); nunca some (trigger). Dado clínico fora de inspect,
# to_s, pretty_print e as_json.
class DentalTreatmentPlanItem < ApplicationRecord
  encrypts :cancel_reason

  belongs_to :dental_treatment_plan, inverse_of: :items
  belongs_to :added_in_consultation, class_name: "Consultation"
  belongs_to :done_in_consultation, class_name: "Consultation", optional: true
  belongs_to :cancelled_in_consultation, class_name: "Consultation", optional: true
  belongs_to :cancelled_in_addendum, class_name: "ConsultationAddendum", optional: true

  def inspect = "#<DentalTreatmentPlanItem id=#{id} dental_treatment_plan_id=#{dental_treatment_plan_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
