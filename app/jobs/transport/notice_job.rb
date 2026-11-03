# Consumidor dos eventos de viagem e de passageiro (ADR 0048; Desvio 8; §14
# T15): só reparte — um Transport::PassengerNoticeJob por passageiro, cada um
# com o Transport::Notify na própria transação (Ruling I-1, como o lembrete do
# 17): a falha de um passageiro não desfaz nem reenvia o SMS dos outros. O
# Notify filtra (viagem confirmed/in_progress; cancelamento só da que tinha
# confirmed_at); os eventos saem em toda situação (Tasks 4/5). Com o
# transporte desligado (usable?), nenhum aviso novo.
#   transport.trip_confirmed   → `added` para todos os passageiros ativos;
#   transport.trip_cancelled   → `cancelled` para os ativos (só com confirmed_at);
#   transport.passenger_added  → `added`; transport.passenger_removed → `removed`;
#   transport.trip_changed     → `departure`: `departure_changed` para os ativos;
#     `boarding`: `boarding_changed` para os ativos da parada; chave = id do
#     evento (o Notify compara com o último valor avisado, Ruling I-2).
# Payload só com ids e o código da mudança. O nome e o id do evento vêm do
# perform (o payload do trip_confirmed e do trip_cancelled é o mesmo).
module Transport
  class NoticeJob < ApplicationJob
    include IdempotentConsumer
    queue_as :default

    def perform(event_id:, event_name:, **)
      @event_id = event_id
      @event_name = event_name
      super
    end

    def handle(trip_id:, passenger_id: nil, change: nil, stop_id: nil, **)
      return unless Gate.usable?(Current.city)

      trip = TransportTrip.find(trip_id)
      case @event_name
      when "transport.trip_confirmed" then fan_out(trip.transport_trip_passengers, "added")
      when "transport.trip_cancelled" then fan_out(trip.transport_trip_passengers, "cancelled") if trip.confirmed_at
      when "transport.passenger_added" then fan_out(trip.transport_trip_passengers.where(id: passenger_id), "added")
      when "transport.passenger_removed" then fan_out(trip.transport_trip_passengers.where(id: passenger_id), "removed", active: false)
      when "transport.trip_changed" then changed(trip, change, stop_id)
      end
    end

    private

    def changed(trip, change, stop_id)
      case change
      when "departure" then fan_out(trip.transport_trip_passengers, "departure_changed", @event_id)
      when "boarding"
        fan_out(trip.transport_trip_passengers.where(transport_trip_stop_id: stop_id), "boarding_changed", @event_id)
      end
    end

    # Enfileirado só depois do COMMIT (enqueue_after_transaction_commit).
    def fan_out(passengers, kind, event_key = "once", active: true)
      scope = passengers.where(anonymized_at: nil)
      scope = scope.active if active
      scope.order(:id).pluck(:id).each do |id|
        PassengerNoticeJob.perform_later(city_slug: Current.city.slug, passenger_id: id, kind: kind, event_key: event_key)
      end
    end
  end
end
