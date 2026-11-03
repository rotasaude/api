# POST /transport/trips/:id/cancel (contrato §4; T15; T19): `planned` ou
# `confirmed` → `cancelled`, com motivo de 10 a 500 caracteres (cifrado). A
# cancelada sai das exclusion constraints: o veículo e o motorista ficam
# livres no horário. Viagem `in_progress`, `done` ou `cancelled` →
# `invalid_transition` (C3: o cancelamento é uma transição). Evento `transport.trip_cancelled` (só o id) em todo
# cancelamento (§11); o aviso ao cidadão (T15) é decisão do consumidor, que
# só avisa a viagem que tinha `confirmed_at` (fica gravado no cancelamento).
# Os trechos de frota do TFD abertos dos passageiros ficam anulados
# (`trip_cancelled`, FR I1).
module Transport
  module CancelTrip
    CANCELLABLE = %w[planned confirmed].freeze

    module_function

    # -> Result.ok(trip:) | fail(:invalid_request, details: { path: "reason", problems: }) | fail(:invalid_transition)
    def call(trip:, reason:, by:)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:invalid_transition) unless CANCELLABLE.include?(trip.status)

        text = Support.text(reason, Catalog::REASON)
        next Support.refuse("reason") unless text

        trip.update!(status: "cancelled", cancelled_at: Time.current, cancelled_by_user: by, cancel_reason: text)
        Tfd::FleetLegs.void!(trip.transport_trip_passengers.select(:id), "trip_cancelled")
        DomainEvents.publish("transport.trip_cancelled", trip_id: trip.id)
        Result.ok(trip: trip)
      end
    end
  end
end
