# GET/POST/PATCH /transport/vehicles[/:id] (contrato §4): frota, ordenada pela placa.
module Transport
  class VehiclesController < BaseController
    include FleetResource

    private

    def resource_class = TransportVehicle
    def command = SaveVehicle
    def result_key = :vehicle
    def ordered(scope) = scope.order(:plate)
    def render_record(record) = Json.vehicle(record)
  end
end
