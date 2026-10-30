# Pedido de prótese (ADR 0046; Desvio 12): moldado numa consulta, para um
# laboratório (prestador do 26a ou terceiro por nome). Etapas impression →
# sent → received → installed (só pela finalização), ou cancelled antes de
# instalado; instalado e cancelado nunca mudam; nunca some (trigger). Dado
# clínico fora de inspect, to_s, pretty_print e as_json.
class DentalProsthesisOrder < ApplicationRecord
  belongs_to :patient
  belongs_to :health_unit
  belongs_to :consultation
  belongs_to :care_provider, optional: true
  belongs_to :installed_in_consultation, class_name: "Consultation", optional: true
  belongs_to :created_by_user, class_name: "User"
  has_many :stages, class_name: "DentalProsthesisStage", inverse_of: :dental_prosthesis_order, dependent: :restrict_with_error

  def inspect = "#<DentalProsthesisOrder id=#{id} patient_id=#{patient_id} health_unit_id=#{health_unit_id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
