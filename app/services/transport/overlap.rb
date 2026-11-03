# Sobreposição de viagens (ADR 0048; Desvio 2): a mesma pergunta das exclusion
# constraints `excl_transport_trips_vehicle`/`_driver` (tsrange [) — a volta
# às 12:00 e a saída às 12:00 não se cruzam), feita em SQL antes de gravar
# para devolver todas as recusas de uma vez. Ignora a própria viagem e as
# canceladas. A constraint continua a última palavra (corrida entre dois
# pedidos): o Transport::SaveTrip traduz a violação pelo nome dela.
module Transport
  module Overlap
    module_function

    # trip: TransportTrip (salvo ou não, com os valores pretendidos).
    # -> [ { path: "vehicle_id", error: "vehicle_overlap" }, { path: "driver_id", error: "driver_overlap" } ] (só os que cruzam)
    def problems(trip)
      return [] unless trip.departure_at && trip.return_at

      scope = TransportTrip.where.not(status: "cancelled")
                           .where("tsrange(departure_at, return_at) && tsrange(?::timestamp, ?::timestamp)", trip.departure_at, trip.return_at)
      scope = scope.where.not(id: trip.id) if trip.id
      out = []
      if trip.transport_vehicle_id && scope.where(transport_vehicle_id: trip.transport_vehicle_id).exists?
        out << { path: "vehicle_id", error: "vehicle_overlap" }
      end
      if trip.transport_driver_id && scope.where(transport_driver_id: trip.transport_driver_id).exists?
        out << { path: "driver_id", error: "driver_overlap" }
      end
      out
    end
  end
end
