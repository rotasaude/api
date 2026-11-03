# POST /transport/my_trips/:id/start (contrato §5; §14 T19): o motorista sai
# com a viagem `confirmed`, só no dia LOCAL dela (Time.zone da cidade) →
# `in_progress` e `started_at`. Outra situação → `invalid_transition`; outro
# dia → `trip_not_today`. A CNH é conferida de novo (FW2): vencida antes do
# dia da viagem → `driver_license_expired`; veículo de mais de 8 lugares sem
# categoria D/E → `driver_license_category` (o cadastro pode ter mudado depois
# da confirmação). Evento transport.trip_started (só o id).
module Transport
  module StartTrip
    module_function

    # -> Result.ok(trip:) | fail(:invalid_transition | :trip_not_today | :driver_license_expired | :driver_license_category)
    def call(trip:, by:, today: Time.zone.today)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:invalid_transition) unless trip.status == "confirmed"
        next Result.fail(:trip_not_today) unless trip.date == today

        license = license_problems(trip)
        next Support.failure(license) if license.any?

        trip.update!(status: "in_progress", started_at: Time.current)
        DomainEvents.publish("transport.trip_started", trip_id: trip.id)
        Result.ok(trip: trip)
      end
    end

    # A escala confirmada sempre tem veículo e motorista (ck_transport_trips_staffed).
    def license_problems(trip)
      driver = TransportDriver.find(trip.transport_driver_id)
      vehicle = TransportVehicle.find(trip.transport_vehicle_id)
      out = []
      out << { path: "driver_id", error: "driver_license_expired" } if driver.license_expires_on < trip.date
      if vehicle.seats > Catalog::LARGE_VEHICLE_SEATS && Catalog::LARGE_VEHICLE_CATEGORIES.exclude?(driver.license_category)
        out << { path: "driver_id", error: "driver_license_category" }
      end
      out
    end
    private_class_method :license_problems
  end
end
