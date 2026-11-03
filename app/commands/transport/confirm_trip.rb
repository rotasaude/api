# POST /transport/trips/:id/confirm (contrato §4; Desvio 7; T19): `planned` →
# `confirmed`. Exige veículo e motorista (`vehicle_required`,
# `driver_required`), veículo ativo (`vehicle_inactive`), motorista ativo, CNH
# não vencida na data da viagem (`driver_license_expired`), CNH D/E para
# veículo de mais de 8 lugares (`driver_license_category`) e lotação que caiba
# (`seats_full`/`wheelchair_full`) — todas as recusas de uma vez. As mesmas
# regras valem para a troca de veículo ou motorista numa viagem já confirmada
# (Transport::SaveTrip). Viagem `done`/`cancelled` → `trip_not_open`; outra →
# `invalid_transition`. Evento `transport.trip_confirmed` só com o id.
module Transport
  module ConfirmTrip
    CLOSED = %w[done cancelled].freeze

    module_function

    # -> Result.ok(trip:) | fail(<primeira recusa>, details: { path:, problems: }) | fail(:trip_not_open | :invalid_transition)
    def call(trip:, by:)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:trip_not_open) if CLOSED.include?(trip.status)
        next Result.fail(:invalid_transition) unless trip.status == "planned"

        problems = rules(trip, trip.transport_vehicle, trip.transport_driver)
        next Support.failure(problems) if problems.any?

        trip.update!(status: "confirmed", confirmed_at: Time.current)
        DomainEvents.publish("transport.trip_confirmed", trip_id: trip.id)
        Result.ok(trip: trip)
      end
    end

    # Regras da escala de uma viagem confirmada (ou a confirmar) com `vehicle`
    # e `driver`. -> [ { path:, error: } ]
    def rules(trip, vehicle, driver)
      out = []
      out << { path: "vehicle_id", error: "vehicle_required" } unless vehicle
      out << { path: "driver_id", error: "driver_required" } unless driver
      out << { path: "vehicle_id", error: "vehicle_inactive" } if vehicle && !vehicle.active
      if driver
        out << { path: "driver_id", error: "invalid_request" } unless driver.active
        out << { path: "driver_id", error: "driver_license_expired" } if driver.license_expires_on < trip.date
        if vehicle && vehicle.seats > Catalog::LARGE_VEHICLE_SEATS && Catalog::LARGE_VEHICLE_CATEGORIES.exclude?(driver.license_category)
          out << { path: "driver_id", error: "driver_license_category" }
        end
      end
      out + Occupancy.problems(trip, vehicle)
    end
  end
end
