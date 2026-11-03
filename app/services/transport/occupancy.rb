# Lotação da viagem (ADR 0048; Desvio 3): lugares = passageiros ativos (não
# retirados) que ocupam assento + acompanhantes ativos; cadeirantes =
# passageiros ativos com cadeira de rodas. Sem veículo (planned sem escala),
# sem limite: `seats`/`wheelchair_spots` nulos.
module Transport
  module Occupancy
    module_function

    # -> { seats_used:, seats:, wheelchair_used:, wheelchair_spots: }
    def of(trip, vehicle: trip.transport_vehicle)
      used = usage(trip)
      { seats_used: used[:seats], seats: vehicle&.seats, wheelchair_used: used[:wheelchair], wheelchair_spots: vehicle&.wheelchair_spots }
    end

    # Recusas de lotação se a viagem passasse a usar `vehicle`:
    # [ { path: "vehicle_id", error: "seats_full" | "wheelchair_full" } ].
    def problems(trip, vehicle)
      return [] unless vehicle

      used = usage(trip)
      out = []
      out << { path: "vehicle_id", error: "seats_full" } if used[:seats] > vehicle.seats
      out << { path: "vehicle_id", error: "wheelchair_full" } if used[:wheelchair] > vehicle.wheelchair_spots
      out
    end

    # O que falta para mais um passageiro (assento se `takes_seat`, cadeira se
    # `wheelchair`, mais um lugar para o acompanhante) caber, com o que já
    # está ativo: [] | ["seats_full"] | ["wheelchair_full"] | os dois. Sem
    # veículo, sem limite.
    def shortfall(trip, takes_seat:, wheelchair:, companion:, vehicle: trip.transport_vehicle)
      return [] unless vehicle

      used = usage(trip)
      out = []
      out << "seats_full" if used[:seats] + (takes_seat ? 1 : 0) + (companion ? 1 : 0) > vehicle.seats
      out << "wheelchair_full" if wheelchair && used[:wheelchair] + 1 > vehicle.wheelchair_spots
      out
    end

    def fits?(trip, takes_seat:, wheelchair:, companion:) = shortfall(trip, takes_seat:, wheelchair:, companion:).empty?

    # Acompanhante = companion_attendance preenchida (o CHECK a amarra ao nome;
    # sobrevive à anonimização).
    def usage(trip)
      return { seats: 0, wheelchair: 0 } unless trip.id

      active = TransportTripPassenger.active.where(transport_trip_id: trip.id)
      seats, companions, wheelchair = active.pick(
        Arel.sql("COUNT(*) FILTER (WHERE takes_seat)"),
        Arel.sql("COUNT(*) FILTER (WHERE companion_attendance IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE wheelchair)")
      )
      { seats: seats.to_i + companions.to_i, wheelchair: wheelchair.to_i }
    end
  end
end
