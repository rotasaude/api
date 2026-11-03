# POST /transport/my_trips/:id/start (contrato §5; §14 T19): o motorista sai
# com a viagem `confirmed`, só no dia LOCAL dela (Time.zone da cidade) →
# `in_progress` e `started_at`. Outra situação → `invalid_transition`; outro
# dia → `trip_not_today`. Evento transport.trip_started (só o id).
module Transport
  module StartTrip
    module_function

    # -> Result.ok(trip:) | fail(:invalid_transition | :trip_not_today)
    def call(trip:, by:, today: Time.zone.today)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:invalid_transition) unless trip.status == "confirmed"
        next Result.fail(:trip_not_today) unless trip.date == today

        trip.update!(status: "in_progress", started_at: Time.current)
        DomainEvents.publish("transport.trip_started", trip_id: trip.id)
        Result.ok(trip: trip)
      end
    end
  end
end
