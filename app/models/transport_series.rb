# Série recorrente (ADR 0048; hemodiálise, quimioterapia): dias ISO
# (1 = segunda … 7 = domingo), horários locais ("HH:MM"), embarque e, cifrados
# com a chave da cidade, prestador, endereço, acompanhante e o motivo da
# suspensão. O job materializa as viagens no horizonte. Nunca é apagada
# (trigger). Dado do paciente nunca sai em inspect, to_s, pretty_print nem
# as_json — só o id.
class TransportSeries < ApplicationRecord
  encrypts :provider_name, :address, :companion_name, :companion_document, :companion_reason, :suspend_reason

  belongs_to :patient
  belongs_to :transport_destination
  belongs_to :created_by_user, class_name: "User"
  has_many :transport_trips, inverse_of: :transport_series, dependent: :restrict_with_error
  has_many :transport_pending_items, inverse_of: :transport_series, dependent: :restrict_with_error

  def inspect = "#<TransportSeries id=#{id}>"
  def to_s = inspect
  def pretty_print(pp) = pp.text(inspect)
  def as_json(*) = { "id" => id }
end
