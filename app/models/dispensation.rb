# Dispensação (ADR 0045): pela receita do 19c (clinical_document) ou pela
# externa, uma das duas; quem dispensou e com que papel; retenção e o número
# da notificação cifrado. Só a re-cifra regrava (trigger). Nada do paciente em
# inspect, to_s, pretty_print ou as_json.
class Dispensation < ApplicationRecord
  encrypts :notification_number

  belongs_to :stock_location
  belongs_to :patient
  belongs_to :clinical_document, optional: true
  belongs_to :external_prescription, optional: true
  belongs_to :dispensed_by_user, class_name: "User"
  has_many :items, class_name: "DispensationItem", inverse_of: :dispensation

  def inspect = "#<Dispensation id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
