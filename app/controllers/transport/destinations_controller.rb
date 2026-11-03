# GET/POST/PATCH /transport/destinations[/:id] (contrato §4): destinos, ordenados pelo nome.
module Transport
  class DestinationsController < BaseController
    include FleetResource

    private

    def resource_class = TransportDestination
    def command = SaveDestination
    def result_key = :destination
    def ordered(scope) = scope.order(:name, :id)
    def render_record(record) = Json.destination(record)
  end
end
