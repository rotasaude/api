# Receita externa digitada na farmácia (ADR 0045): prescritor, conselho e a
# data; o número da notificação cifrado. Só a re-cifra regrava (trigger). Nada
# do paciente nem da receita em inspect, to_s, pretty_print ou as_json.
class ExternalPrescription < ApplicationRecord
  encrypts :notification_number
  # O prescritor (nome e conselho) nunca no inspect do ActiveRecord. O log do
  # SQL (binds) usa a lista GLOBAL: as mesmas colunas estão em
  # config/initializers/filter_parameter_logging.rb.
  self.filter_attributes += %i[prescriber_name council council_state council_number]

  belongs_to :patient
  belongs_to :stock_location
  belongs_to :recorded_by_user, class_name: "User"
  has_many :items, -> { order(:position) }, class_name: "ExternalPrescriptionItem", inverse_of: :external_prescription

  def inspect = "#<ExternalPrescription id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
