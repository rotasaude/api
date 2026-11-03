# Materializa uma série recorrente nos 21 dias a partir de `today` (contrato
# §4; ADR 0048; plano, Task 7; Review Focus 2). Para cada dia `d` em que a
# série vale (TransportSeries#runs_on?):
#   1. o paciente já está, pela série, ATIVO numa viagem NÃO cancelada do
#      dia → nada (e a pendência aberta desse dia, se houver, fica resolvida:
#      a central o pôs à mão); retirado ou viagem cancelada → o dia volta;
#   2. já há pendência ABERTA da série no dia → nada;
#   3. viagens `planned`/`confirmed` do dia com parada de destino no município
#      da série, travadas (FOR UPDATE), da saída mais próxima à da série: entra
#      na primeira em que cabe (Transport::Occupancy.fits?);
#   4. nenhuma viagem → cria a `planned` sem escala (sem veículo e motorista,
#      autor = quem criou a série; paradas [embarque, destino]); sem escala não
#      há sobreposição a conferir;
#   5. há viagens e nenhuma cabe → pendência `no_seat` ou `no_wheelchair_spot`
#      pelo que falta na viagem mais próxima (Occupancy.shortfall; nunca
#      excesso); a linha resolvida antes para o mesmo dia é reaberta (índice
#      único por série e data).
# O passageiro entra pelo Transport::AddPassenger (origem "series", by: nil),
# na parada de embarque de mesmo rótulo (sem distinção de caixa) ou numa nova,
# antes do primeiro destino. Horas: "HH:MM" da série no fuso da cidade
# (Time.zone.parse("<d> <HH:MM>")), logo `date` = dia local da saída.
# Cada dia num savepoint próprio: a falha de um dia desfaz só as escritas
# dele (viagem, parada, passageiro, pendência), vai ao log só com o id da
# série, a data e a classe do erro, e conta em `failed`; os outros dias
# seguem. Quem chama abre a transação da série (o job, com a série travada).
# Nada do paciente sai daqui: só contagens.
module Transport
  module MaterializeSeries
    POSITION_SHIFT = 1000

    # Recusa inesperada do AddPassenger (a mensagem é só o código).
    class Refused < StandardError; end

    module_function

    # -> { added:, created_trips:, pending:, failed: } (contagens desta execução)
    def call(series:, today:)
      counts = { added: 0, created_trips: 0, pending: 0, failed: 0 }
      (today..(today + Catalog::SERIES_HORIZON_DAYS - 1)).each do |d|
        next unless series.runs_on?(d)

        day = { added: 0, created_trips: 0, pending: 0 }
        TransportTrip.transaction(requires_new: true) { materialize_day(series, d, day) }
        day.each { |key, value| counts[key] += value }
      rescue => e
        counts[:failed] += 1
        Rails.logger.error("[#{name}] series=#{series.id} date=#{d.iso8601} failed: #{e.class}")
      end
      counts
    end

    def materialize_day(series, d, counts)
      if already_on_trip?(series, d)
        series.transport_pending_items.where(date: d, resolved_at: nil).update_all(resolved_at: Time.current)
        return
      end
      return if series.transport_pending_items.exists?(date: d, resolved_at: nil)

      departure = local(d, series.clock(:departure_time))
      candidates = candidates(series, d, departure)
      need = { takes_seat: !series.wheelchair, wheelchair: series.wheelchair, companion: series.companion_name.present? }
      trip = candidates.find { |t| Occupancy.fits?(t, **need) }
      if trip.nil? && candidates.empty?
        trip = create_planned_trip!(series, d, departure)
        counts[:created_trips] += 1
      elsif trip.nil?
        open_pending!(series, d, pending_reason(candidates.first, need))
        counts[:pending] += 1
        return
      end
      counts[:added] += 1 if add_passenger!(trip, series, d)
    end

    def already_on_trip?(series, d)
      TransportTripPassenger.active.joins(:transport_trip)
                            .where(transport_series_id: series.id, transport_trips: { date: d })
                            .where.not(transport_trips: { status: "cancelled" }).exists?
    end

    # O que falta na viagem mais próxima: faltou lugar → no_seat; só a
    # cadeira → no_wheelchair_spot.
    def pending_reason(trip, need)
      Occupancy.shortfall(trip, **need).include?("seats_full") ? "no_seat" : "no_wheelchair_spot"
    end

    def open_pending!(series, d, reason)
      resolved = series.transport_pending_items.find_by(date: d)
      return resolved.update!(resolved_at: nil, reason: reason) if resolved

      TransportPendingItem.create!(transport_series: series, date: d, reason: reason)
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

    # -> true se entrou; false se o paciente já estava na viagem por outra
    # origem (sem tocar nas paradas). Outra recusa levanta Refused e o
    # savepoint do dia desfaz a parada nova.
    def add_passenger!(trip, series, d)
      return false if TransportTripPassenger.active.exists?(transport_trip_id: trip.id, patient_id: series.patient_id)

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

    private_class_method :materialize_day, :already_on_trip?, :pending_reason, :open_pending!, :candidates, :create_planned_trip!, :add_passenger!, :boarding_stop!,
                         :local
  end
end
