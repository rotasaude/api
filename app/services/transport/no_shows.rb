# Faltas por paciente (ADR 0048; contrato §4, T18): passageiros `no_show` de
# viagens `done` com a data da viagem entre `from` e `to`, mais faltas primeiro.
# Sem destino, prestador nem dado clínico: só o paciente, a contagem e as datas.
module Transport
  module NoShows
    module_function

    # -> [ { patient: { id:, display_name: }, count:, dates: [ Date ] } ]
    def call(from:, to:)
      rows = TransportTripPassenger.active.where(attendance: "no_show")
                                   .joins(:transport_trip).merge(TransportTrip.where(status: "done", date: from..to))
                                   .includes(:patient).order("transport_trips.date", "transport_trip_passengers.id")
                                   .map { |passenger| [ passenger.patient, passenger.transport_trip.date ] }
      rows.group_by { |patient, _| patient.id }.values.map do |group|
        patient = group.first.first
        { patient: { id: patient.id, display_name: patient.display_name }, count: group.size, dates: group.map(&:last) }
      end.sort_by { |item| [ -item[:count], item[:patient][:display_name].to_s, item[:patient][:id] ] }
    end
  end
end
