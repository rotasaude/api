# POST /transport/trips/:id/cancel (contrato §4; T15; T19): `planned` ou
# `confirmed` → `cancelled`, com motivo de 10 a 500 caracteres (cifrado). A
# cancelada sai das exclusion constraints: o veículo e o motorista ficam
# livres no horário. Viagem `done`/`cancelled` → `trip_not_open`; `in_progress`
# → `invalid_transition`. Evento `transport.trip_cancelled` (só o id) só
# quando a viagem estava confirmada: a `planned` não tem aviso (T15).
module Transport
  module CancelTrip
    CANCELLABLE = %w[planned confirmed].freeze

    module_function

    # -> Result.ok(trip:) | fail(:invalid_request, details: { path: "reason", problems: }) | fail(:trip_not_open | :invalid_transition)
    def call(trip:, reason:, by:)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:trip_not_open) if ConfirmTrip::CLOSED.include?(trip.status)
        next Result.fail(:invalid_transition) unless CANCELLABLE.include?(trip.status)

        text = Support.text(reason, Catalog::REASON)
        next Support.refuse("reason") unless text

        was_confirmed = trip.status == "confirmed"
        trip.update!(status: "cancelled", cancelled_at: Time.current, cancelled_by_user: by, cancel_reason: text)
        DomainEvents.publish("transport.trip_cancelled", trip_id: trip.id) if was_confirmed
        Result.ok(trip: trip)
      end
    end
  end
end
