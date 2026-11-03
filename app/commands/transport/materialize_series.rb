# Materializa uma série recorrente nos 21 dias a partir de `today` (contrato
# §4; ADR 0048; plano, Task 7; Review Focus 2). Para cada dia `d` em que a
# série vale (TransportSeries#runs_on?):
#   1. o paciente já está, pela série, numa viagem do dia → nada (e a
#      pendência aberta desse dia, se houver, fica resolvida: a central o pôs
#      à mão);
#   2. já há pendência da série no dia → nada (uma por série e data, índice
#      único; a resolvida pela suspensão também não volta);
#   3. viagens `planned`/`confirmed` do dia com parada de destino no município
#      da série, travadas (FOR UPDATE), da saída mais próxima à da série: entra
#      na primeira em que cabe (Transport::Occupancy.fits?);
#   4. nenhuma viagem → cria a `planned` sem escala (sem veículo e motorista,
#      autor = quem criou a série; paradas [embarque, destino]); sem escala não
#      há sobreposição a conferir;
#   5. há viagens e nenhuma cabe → pendência `no_seat` ou `no_wheelchair_spot`
#      (nunca excesso).
# O passageiro entra pelo Transport::AddPassenger (origem "series", by: nil),
# na parada de embarque de mesmo rótulo (sem distinção de caixa) ou numa nova,
# antes do primeiro destino. Horas: "HH:MM" da série no fuso da cidade
# (Time.zone.parse("<d> <HH:MM>")), logo `date` = dia local da saída.
# Quem chama abre a transação (uma por série, o job). Nada do paciente sai
# daqui: só contagens.
module Transport
  module MaterializeSeries
    POSITION_SHIFT = 1000

    # Recusa inesperada do AddPassenger (a mensagem é só o código).
    class Refused < StandardError; end

    module_function

    # -> { added:, created_trips:, pending: } (contagens desta execução)
    def call(series:, today:)
      counts = { added: 0, created_trips: 0, pending: 0 }
      (today..(today + Catalog::SERIES_HORIZON_DAYS - 1)).each do |d|
        next unless series.runs_on?(d)

        materialize_day(series, d, counts)
      end
      counts
    end

    def materialize_day(series, d, counts)
      if already_on_trip?(series, d)
        series.transport_pending_items.where(date: d, resolved_at: nil).update_all(resolved_at: Time.current)
        return
      end
      return if series.transport_pending_items.exists?(date: d)

      departure = local(d, series.clock(:departure_time))
      candidates = candidates(series, d, departure)
      need = { takes_seat: !series.wheelchair, wheelchair: series.wheelchair, companion: series.companion_name.present? }
      trip = candidates.find { |t| Occupancy.fits?(t, **need) }
      if trip.nil? && candidates.empty?
        trip = create_planned_trip!(series, d, departure)
        counts[:created_trips] += 1
      elsif trip.nil?
        TransportPendingItem.create!(transport_series: series, date: d, reason: series.wheelchair ? "no_wheelchair_spot" : "no_seat")
        counts[:pending] += 1
        return
      end
      counts[:added] += 1 if add_passenger!(trip, series, d)
    end

    def already_on_trip?(series, d)
      TransportTripPassenger.joins(:transport_trip)
                            .where(transport_series_id: series.id, removed_at: nil, transport_trips: { date: d }).exists?
    end

    def candidates(series, d, departure)
      with_destination = TransportTripStop.where(kind: "destination", transport_destination_id: series.transport_destination_id)
                                          .select(:transport_trip_id)
      distance = TransportTrip.sanitize_sql_array([ "abs(extract(epoch from departure_at - ?::timestamp))", departure.utc ])
      TransportTrip.where(date: d, status: Catalog::OPEN_STATUSES).where(id: with_destination)
                   .order(Arel.sql(distance), :id).lock.to_a
    end

    def create_planned_trip!(series, d, departure)
      destination = series.transport_destination
      trip = TransportTrip.create!(departure_at: departure, return_at: local(d, series.clock(:return_time)), status: "planned",
                                   transport_series: series, created_by_user: series.created_by_user)
      trip.transport_trip_stops.create!(position: 1, kind: "boarding", label: series.boarding_label)
      trip.transport_trip_stops.create!(position: 2, kind: "destination", transport_destination: destination,
                                        label: destination.name.to_s[0, Catalog::TEXT_MAX])
      trip
    end

    # -> true se entrou; false se o paciente já estava na viagem por outra origem.
    def add_passenger!(trip, series, d)
      stop = boarding_stop!(trip, series.boarding_label)
      attrs = { "patient_id" => series.patient_id, "origin" => "series", "origin_id" => series.id, "stop_id" => stop.id,
                "destination_id" => series.transport_destination_id,
                "appointment_at" => local(d, series.clock(:appointment_time)).iso8601,
                "takes_seat" => !series.wheelchair, "wheelchair" => series.wheelchair }
      attrs["provider_name"] = series.provider_name if series.provider_name
      if series.companion_name
        attrs["companion"] = { "name" => series.companion_name, "document" => series.companion_document,
                               "reason" => series.companion_reason }.compact
      end
      result = AddPassenger.call(trip: trip, attrs: attrs, by: nil)
      return true if result.ok?
      return false if result.reason == :patient_already_on_trip

      raise Refused, result.reason.to_s
    end

    # Parada de embarque de mesmo rótulo (sem distinção de caixa) ou uma nova
    # logo antes do primeiro destino (as seguintes andam uma posição; o índice
    # único por viagem pede o deslocamento em dois passos).
    def boarding_stop!(trip, label)
      stops = trip.transport_trip_stops.reload.to_a
      found = stops.find { |s| s.kind == "boarding" && s.label.downcase == label.downcase }
      return found if found

      position = stops.find { |s| s.kind == "destination" }.position
      after = TransportTripStop.where(transport_trip_id: trip.id).where(position: position..)
      after.update_all([ "position = position + ?", POSITION_SHIFT ])
      TransportTripStop.where(transport_trip_id: trip.id).where(position: (position + POSITION_SHIFT)..)
                       .update_all([ "position = position - ?", POSITION_SHIFT - 1 ])
      stop = trip.transport_trip_stops.create!(position: position, kind: "boarding", label: label)
      trip.transport_trip_stops.reset
      stop
    end

    def local(d, clock) = Time.zone.parse("#{d.iso8601} #{clock}")

    private_class_method :materialize_day, :already_on_trip?, :candidates, :create_planned_trip!, :add_passenger!, :boarding_stop!,
                         :local
  end
end
