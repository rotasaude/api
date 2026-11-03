# Parada da viagem (ADR 0048): embarque (rótulo) ou destino (município), em
# ordem. Parada com passageiro não sai (trigger).
class TransportTripStop < ApplicationRecord
  belongs_to :transport_trip, inverse_of: :transport_trip_stops
  belongs_to :transport_destination, optional: true
  has_many :transport_trip_passengers, inverse_of: :transport_trip_stop, dependent: :restrict_with_error
end
