# DELETE /transport/trips/:id/passengers/:pid { reason } (contrato §4; §14 T19,
# T23): grava `removed_at`, `removed_by_user` e o motivo (10..500, cifrado) — a
# linha nunca some (trigger) e a vaga volta (a lotação só conta ativos).
#   - passageiro anonimizado (LGPD) → `passenger_anonymized` (a linha é
#     congelada pelo trigger; nunca 500);
#   - viagem fora de planned/confirmed → `trip_not_open`;
#   - já retirado → `not_found`.
# Em viagem `confirmed`, evento transport.passenger_removed (só ids; o aviso
# `removed` é da Task 14).
module Transport
  module RemovePassenger
    module_function

    # -> Result.ok(passenger:) | fail(:invalid_request, details: { path: "reason", problems: }) |
    #    fail(:passenger_anonymized | :trip_not_open | :not_found)
    def call(passenger:, reason:, by:)
      return Result.fail(:passenger_anonymized) if passenger.anonymized_at

      text = Support.text(reason, Catalog::REASON)
      return Support.refuse("reason") unless text

      trip = passenger.transport_trip
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        passenger.lock!
        next Result.fail(:passenger_anonymized) if passenger.anonymized_at
        next Result.fail(:trip_not_open) unless Catalog::OPEN_STATUSES.include?(trip.status)
        next Result.fail(:not_found) if passenger.removed_at

        passenger.update!(removed_at: Time.current, removed_by_user: by, remove_reason: text)
        DomainEvents.publish("transport.passenger_removed", trip_id: trip.id, passenger_id: passenger.id) if trip.status == "confirmed"
        Result.ok(passenger: passenger)
      end
    end
  end
end
