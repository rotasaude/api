# Viagem (ADR 0048): saída e volta (até 72 h), veículo e motorista (nulos só em
# `planned`), paradas e passageiros. Veículo e motorista nunca em duas viagens
# que se cruzam (exclusion GiST, [)); a cancelada não ocupa. A data é o dia
# LOCAL da saída, no fuso da cidade (Time.zone, fixado pelo CityConnection):
# sem CHECK no banco (o dump é um só para cidades de fuso diferente), por isso
# derivada aqui antes de toda validação. Motivo do cancelamento cifrado.
# Nunca é apagada (trigger).
class TransportTrip < ApplicationRecord
  encrypts :cancel_reason

  belongs_to :transport_vehicle, optional: true, inverse_of: :transport_trips
  belongs_to :transport_driver, optional: true, inverse_of: :transport_trips
  belongs_to :transport_series, optional: true, inverse_of: :transport_trips
  belongs_to :cancelled_by_user, class_name: "User", optional: true
  belongs_to :created_by_user, class_name: "User"
  has_many :transport_trip_stops, -> { order(:position) }, inverse_of: :transport_trip, dependent: :restrict_with_error
  has_many :transport_trip_passengers, inverse_of: :transport_trip, dependent: :restrict_with_error
  has_one :transport_trip_log, inverse_of: :transport_trip, dependent: :restrict_with_error

  before_validation { self.date = departure_at.in_time_zone.to_date if departure_at }

  def inspect = "#<TransportTrip id=#{id} status=#{status}>"
end
