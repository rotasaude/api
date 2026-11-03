# POST/PATCH /transport/trips[/:id] (contrato §4; Desvios 1, 2, 7; T4, T19,
# T22). Corpo `{ date, departure_at, return_at, vehicle_id?, driver_id?, stops }`
# (PATCH parcial). Ordem: forma (todas as recusas de uma vez), regras com o
# banco (escala da confirmada, lotação, paradas em uso, sobreposição), escrita
# com a viagem travada. Horas ISO 8601 com fuso; `date` = dia LOCAL da saída
# (no fuso da cidade; sem CHECK no banco, T22). Volta depois da saída e até
# 72 h. `planned` aceita veículo e motorista nulos; `confirmed` nunca os anula
# e troca só com as regras do confirm. Lotação nova conferida na troca de
# veículo. Paradas (T4): `[ { id?, position?, kind, destination_id?, label } ]`
# — `position` (1..n, únicos) ordena; sem nenhuma, a ordem do corpo; ao menos
# um embarque e um destino, embarques antes; rótulo 3–120 (o do destino, vazio,
# vira o nome do município). O PATCH com `stops` substitui a lista: as de `id`
# ficam, as ausentes saem — parada que já teve passageiro (mesmo retirado) não
# sai (`stop_in_use`). Sobreposição pela pergunta do Transport::Overlap e,
# numa corrida, pela exclusion constraint (`vehicle_overlap`/`driver_overlap`,
# 422). Só `planned`/`confirmed` mudam (`trip_not_open` em done/cancelled,
# `invalid_transition` em in_progress). Na confirmada, toda mudança da saída e
# do rótulo de embarque publica `transport.trip_changed` (só ids e o código da
# mudança); o limiar de 30 min é do consumidor (Transport::Notify, que compara
# com o último valor avisado — Task 14, Ruling I-2). O DIA local da saída não
# muda enquanto a viagem tem trecho de frota do TFD vivo ou passageiro de
# série ativo, nem o dia local da chegada com trecho de VOLTA de frota vivo
# (`trip_day_locked`, em `date`/`return_at`; FR I2): o trecho leva a data da
# viagem (BPA, competência, noites) e a série procura o paciente pelo dia. A
# hora no mesmo dia muda.
module Transport
  module SaveTrip
    KEYS = %w[date departure_at return_at vehicle_id driver_id stops].freeze
    ZONED = CareRegulation::ScheduleExternal::ZONED
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    STOPS_MAX = 20
    LABEL = (3..Catalog::TEXT_MAX)
    POSITION_SHIFT = 1000
    STOP_IN_USE = "stop in use".freeze

    module_function

    # -> Result.ok(trip:) | fail(<primeira recusa>, details: { path:, problems: }) | fail(:trip_not_open | :invalid_transition)
    def call(attrs:, by:, trip: nil)
      attrs = attrs.to_h.stringify_keys.slice(*KEYS)
      TransportTrip.transaction(requires_new: true) do
        trip&.lock!
        next Result.fail(:trip_not_open) if trip && ConfirmTrip::CLOSED.include?(trip.status)
        next Result.fail(:invalid_transition) if trip && trip.status != "planned" && trip.status != "confirmed"

        problems = []
        values = read_fields(attrs, trip, problems)
        stops = read_stops(attrs, trip, problems)
        next Support.failure(problems) if problems.any?

        record = trip || TransportTrip.new(status: "planned", created_by_user: by)
        before = { departure_at: record.departure_at, labels: record.persisted? ? boarding_labels(record) : {} }
        record.assign_attributes(values)
        problems = rules(record, stops)
        next Support.failure(problems) if problems.any?

        record.save!
        replace_stops!(record, stops) if stops
        publish_changes(record, before) if record.status == "confirmed"
        record.transport_trip_stops.reset
        Result.ok(trip: record)
      end
    rescue ActiveRecord::ExclusionViolation => e
      error = e.message.include?("excl_transport_trips_driver") ? "driver_overlap" : "vehicle_overlap"
      Support.failure([ { path: error == "driver_overlap" ? "driver_id" : "vehicle_id", error: error } ])
    rescue ActiveRecord::StatementInvalid => e
      raise unless e.message.include?(STOP_IN_USE)

      Support.failure([ { path: "stops", error: "stop_in_use" } ])
    end

    # Alguma destas paradas já teve passageiro (ativo ou retirado)? A guarda
    # do banco (rota_transport_trip_stop_guard) conta os dois.
    def stops_in_use?(stop_ids) = TransportTripPassenger.where(transport_trip_stop_id: stop_ids).exists?

    # -> atributos da viagem (horas, veículo, motorista); recusas em `problems`.
    def read_fields(attrs, trip, problems)
      values = {}
      departure = time_field(attrs, "departure_at", trip&.departure_at, problems)
      back = time_field(attrs, "return_at", trip&.return_at, problems)
      if departure && back
        if back <= departure then problems << problem("return_at", "return_before_departure")
        elsif back > departure + Catalog::MAX_TRIP_HOURS.hours then problems << problem("return_at")
        end
      end
      check_date(attrs, trip, departure, problems)
      values.merge!(departure_at: departure, date: departure.to_date) if departure
      values[:return_at] = back if back
      read_reference(attrs, "vehicle_id", TransportVehicle, problems) { |v| values[:transport_vehicle] = v }
      read_reference(attrs, "driver_id", TransportDriver, problems) do |driver|
        next problems << problem("driver_id", "driver_inactive") if driver && !driver.active && driver.id != trip&.transport_driver_id

        values[:transport_driver] = driver
      end
      values
    end

    # Na criação, obrigatória; com valor inválido, recusada.
    def time_field(attrs, key, current, problems)
      return current unless attrs.key?(key) || current.nil?

      value = attrs[key]
      time = value.is_a?(String) && value.match?(ZONED) ? parse_time(value) : nil
      problems << problem(key) unless time
      time
    end

    def parse_time(value)
      DateTime.iso8601(value).to_time.in_time_zone
    rescue Date::Error
      nil
    end

    # `date` obrigatória na criação; quando vem, é o dia local da saída.
    def check_date(attrs, trip, departure, problems)
      return if trip && !attrs.key?("date")

      date = Support.date(attrs["date"])
      problems << problem("date") unless date && (departure.nil? || departure.to_date == date)
    end

    # Ausente: fica como está. `nil`: anula. Id: precisa existir.
    def read_reference(attrs, key, klass, problems)
      return unless attrs.key?(key)

      id = attrs[key]
      return yield(nil) if id.nil?

      record = id.is_a?(String) && id.match?(UUID) ? klass.find_by(id: id) : nil
      record ? yield(record) : problems << problem(key)
    end

    # -> nil (sem `stops` no PATCH) | [ { stop:, kind:, position:, label:, destination: } ] em ordem
    def read_stops(attrs, trip, problems)
      unless attrs.key?("stops")
        problems << problem("stops") unless trip
        return nil
      end

      list = attrs["stops"]
      unless list.is_a?(Array) && list.size.between?(1, STOPS_MAX) && list.all?(Hash)
        problems << problem("stops")
        return nil
      end

      existing = trip ? trip.transport_trip_stops.index_by(&:id) : {}
      seen = []
      items = list.each_with_index.map do |raw, index|
        read_stop(raw.stringify_keys, "stops.#{index}", existing, seen, problems)
      end
      positions = read_positions(list, problems)
      kinds_ok = check_composition(items, positions, problems)
      return nil unless kinds_ok && positions && items.all?(&:present?)

      items.each_with_index { |item, index| item[:position] = positions[index] }
      items.sort_by { |item| item[:position] }
    end

    def read_stop(raw, path, existing, seen, problems)
      bad = []
      stop = nil
      if raw.key?("id")
        stop = raw["id"].is_a?(String) && seen.exclude?(raw["id"]) ? existing[raw["id"]] : nil
        stop ? seen << stop.id : bad << "#{path}.id"
      end
      kind = Catalog::STOP_KINDS.include?(raw["kind"]) ? raw["kind"] : nil
      bad << "#{path}.kind" unless kind && (stop.nil? || stop.kind == kind)
      destination = nil
      if kind == "destination"
        id = raw["destination_id"]
        destination = id.is_a?(String) && id.match?(UUID) ? TransportDestination.find_by(id: id) : nil
        destination = nil if destination && !destination.active && destination.id != stop&.transport_destination_id
        bad << "#{path}.destination_id" unless destination
      elsif !raw["destination_id"].nil?
        bad << "#{path}.destination_id"
      end
      label = read_label(raw["label"], kind, destination)
      bad << "#{path}.label" unless label
      problems.concat(bad.map { |p| problem(p) })
      bad.empty? ? { stop: stop, kind: kind, label: label, destination: destination } : nil
    end

    # O rótulo do destino vazio (ou ausente) vira o nome do município.
    def read_label(value, kind, destination)
      if kind == "destination" && (value.nil? || (value.is_a?(String) && value.strip.empty?))
        return destination&.name.to_s[0, Catalog::TEXT_MAX].presence
      end

      Support.text(value, LABEL)
    end

    # -> posições (1..n, na ordem do corpo) | nil com recusas em stops.N.position.
    def read_positions(list, problems)
      given = list.map { |raw| raw.stringify_keys["position"] }
      return (1..list.size).to_a if given.all?(&:nil?)

      bad = given.each_index.select do |index|
        value = given[index]
        !(value.is_a?(Integer) && value.between?(1, list.size)) || given.count(value) > 1
      end
      return given if bad.empty?

      bad.each { |index| problems << problem("stops.#{index}.position") }
      nil
    end

    # Ao menos um embarque e um destino; com as posições válidas, embarques
    # antes dos destinos. -> false se recusou.
    def check_composition(items, positions, problems)
      kinds = items.compact.map { |item| item[:kind] }
      ok = kinds.include?("boarding") && kinds.include?("destination")
      if ok && positions && items.all?(&:present?)
        ordered = items.each_with_index.sort_by { |_item, index| positions[index] }.map { |item, _| item[:kind] }
        ok = ordered == ordered.sort_by { |kind| kind == "boarding" ? 0 : 1 }
      end
      problems << problem("stops") unless ok
      ok
    end

    # Regras com o banco: escala (confirmada), lotação na troca de veículo,
    # paradas em uso e sobreposição. -> [ { path:, error: } ]
    def rules(record, stops)
      out = []
      if record.status == "confirmed"
        out.concat(ConfirmTrip.rules(record, record.transport_vehicle, record.transport_driver))
      elsif record.persisted? && record.transport_vehicle_id_changed?
        out.concat(Occupancy.problems(record, record.transport_vehicle))
      end
      out.concat(day_lock_problems(record)) if record.persisted?
      out << problem("stops", "stop_in_use") if stops && record.persisted? && stops_in_use?(removed_stop_ids(record, stops))
      out.concat(Overlap.problems(record))
      out.uniq
    end

    # FR I2: dia da saída ou da chegada preso aos trechos de frota e à série.
    def day_lock_problems(record)
      riders = TransportTripPassenger.active.where(transport_trip_id: record.id)
      legs = TfdLeg.live.where(mode: "fleet", transport_trip_passenger_id: riders.select(:id))
      out = []
      if record.date_changed? && (riders.exists?(origin: "series") || legs.exists?)
        out << problem("date", "trip_day_locked")
      end
      if record.return_at_changed? && local_day(record.return_at) != local_day(record.return_at_was) && legs.exists?(direction: "return")
        out << problem("return_at", "trip_day_locked")
      end
      out
    end

    def local_day(time) = time&.in_time_zone&.to_date

    def removed_stop_ids(record, stops)
      record.transport_trip_stops.map(&:id) - stops.filter_map { |item| item[:stop]&.id }
    end

    # Apaga as que saem, abre espaço nas posições (índice único por viagem) e
    # grava as mantidas e as novas.
    def replace_stops!(record, stops)
      removed = removed_stop_ids(record, stops)
      TransportTripStop.where(id: removed).delete_all if removed.any?
      kept = stops.filter_map { |item| item[:stop] }
      TransportTripStop.where(id: kept.map(&:id)).update_all([ "position = position + ?", POSITION_SHIFT ]) if kept.any?
      stops.each do |item|
        attrs = { position: item[:position], kind: item[:kind], label: item[:label], transport_destination: item[:destination] }
        if item[:stop]
          item[:stop].reload.update!(attrs)
        else
          record.transport_trip_stops.create!(attrs)
        end
      end
    end

    def boarding_labels(record)
      record.transport_trip_stops.select { |stop| stop.kind == "boarding" }.to_h { |stop| [ stop.id, stop.label ] }
    end

    def publish_changes(record, before)
      if before[:departure_at] && record.departure_at != before[:departure_at]
        DomainEvents.publish("transport.trip_changed", trip_id: record.id, change: "departure")
      end
      after = boarding_labels(record.tap { |r| r.transport_trip_stops.reset })
      before[:labels].each do |stop_id, label|
        next unless after.key?(stop_id) && after[stop_id] != label

        DomainEvents.publish("transport.trip_changed", trip_id: record.id, change: "boarding", stop_id: stop_id)
      end
    end

    def problem(path, error = "invalid_request") = { path: path, error: error }

    private_class_method :read_fields, :time_field, :parse_time, :check_date, :read_reference, :read_stops, :read_stop, :read_label,
                         :read_positions, :check_composition, :rules, :day_lock_problems, :local_day, :removed_stop_ids, :replace_stops!, :boarding_labels,
                         :publish_changes, :problem
  end
end
