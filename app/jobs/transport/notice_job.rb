# Consumidor dos eventos de viagem e de passageiro (ADR 0048; Desvio 8; §14
# T15): vira avisos ao cidadão (Transport::Notify, que só avisa viagem
# confirmed/in_progress e o cancelamento da que tinha confirmed_at). Os
# eventos saem em toda situação (Tasks 4/5); o filtro é daqui.
#   transport.trip_confirmed   → `added` para todos os passageiros ativos;
#   transport.trip_cancelled   → `cancelled` para os ativos;
#   transport.passenger_added  → `added`; transport.passenger_removed → `removed`;
#   transport.trip_changed     → `departure`: `departure_changed`, chave =
#     saída atual em ISO 8601; `boarding`: `boarding_changed` para os ativos da
#     parada, chave = SHA-256 do rótulo atual (16 hex).
# Payload só com ids e o código da mudança. Roda na transação da cidade
# (IdempotentConsumer); o nome do evento vem do perform (o payload do
# trip_confirmed e do trip_cancelled é o mesmo).
module Transport
  class NoticeJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def perform(event_name:, **)
      @event_name = event_name
      super
    end

    def handle(trip_id:, passenger_id: nil, change: nil, stop_id: nil, **)
      trip = TransportTrip.find(trip_id)
      case @event_name
      when "transport.trip_confirmed" then each_active(trip.transport_trip_passengers, "added")
      when "transport.trip_cancelled" then each_active(trip.transport_trip_passengers, "cancelled") if trip.confirmed_at
      when "transport.passenger_added" then Notify.call(passenger: trip.transport_trip_passengers.find(passenger_id), kind: "added")
      when "transport.passenger_removed" then Notify.call(passenger: trip.transport_trip_passengers.find(passenger_id), kind: "removed")
      when "transport.trip_changed" then changed(trip, change, stop_id)
      end
    end

    private

    def changed(trip, change, stop_id)
      case change
      when "departure"
        each_active(trip.transport_trip_passengers, "departure_changed", trip.departure_at.iso8601)
      when "boarding"
        stop = trip.transport_trip_stops.find_by(id: stop_id) or return
        each_active(trip.transport_trip_passengers.where(transport_trip_stop_id: stop.id), "boarding_changed",
                    Digest::SHA256.hexdigest(stop.label)[0, 16])
      end
    end

    def each_active(passengers, kind, event_key = "once")
      passengers.active.where(anonymized_at: nil).order(:id).each do |passenger|
        Notify.call(passenger: passenger, kind: kind, event_key: event_key)
      end
    end
  end
end
