# POST /transport/trips/:id/passengers (contrato §4; §14 T5, T17, T18, T19;
# plano, Desvios 3–6). Ordem:
#   1. forma (todas as recusas de campo de uma vez, `invalid_request`);
#   2. paciente, parada (da viagem) e destino → `not_found`; parada que não é
#      de embarque → `stop_not_boarding`;
#   3. origem (Desvio 4): sem origem e sem motivo → `origin_required`;
#      referência de outro paciente → `origin_mismatch`; referência
#      inexistente ou fora da situação → `invalid_request` em `origin_id`; do
#      TFD, o destino do passageiro é o do processo, senão `invalid_request`
#      em `destination_id` (C8);
#   4. acompanhante (Transport::CompanionRule) → `companion_not_allowed`;
#   5. trava a viagem (FOR UPDATE); fora de planned/confirmed → `trip_not_open`;
#   6. o paciente já ativo nesta viagem → `patient_already_on_trip` (consulta +
#      índice único parcial);
#   7. lotação (Desvio 3) → `seats_full`/`wheelchair_full`, juntas;
#   8. INSERT e evento transport.passenger_added (só ids) em TODA entrada,
#      como o trip_cancelled: o consumidor dos avisos (Task 14) filtra pela
#      situação da viagem (confirmed/in_progress).
# `appointment_at` padrão: o da origem; `provider_name` padrão: o NOME do
# prestador do pedido do 26a ou do TFD — o texto livre `schedule_place` nunca
# (Desvio 6). Nada do paciente, do acompanhante nem do destino em Result.details.
module Transport
  module AddPassenger
    ORIGIN_KEYS = { "regulation" => :regulation_request, "appointment" => :appointment, "tfd" => :tfd_case,
                    "series" => :transport_series }.freeze
    REGULATION_STATUSES = %w[scheduled].freeze
    TFD_STATUSES = %w[authorized scheduled travelling].freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # -> Result.ok(passenger:) | fail(<recusa>, details: { path:, problems: }) | fail(:not_found | :trip_not_open)
    # `attrs`: o corpo JSON (chaves string ou símbolo; a série da Task 7 também chama).
    def call(trip:, attrs:, by:)
      form = shape(attrs.to_h.deep_stringify_keys)
      return Support.refuse(form[:problems]) if form[:problems].any?
      return Support.refuse_with(:origin_required, "origin") unless form[:origin]

      patient = Patient.find_by(id: form[:patient_id])
      stop = trip.transport_trip_stops.find_by(id: form[:stop_id])
      destination = TransportDestination.find_by(id: form[:destination_id])
      return Result.fail(:not_found) unless patient && stop && destination
      return Support.refuse_with(:stop_not_boarding, "stop_id") unless stop.kind == "boarding"

      source = origin_source(form, patient)
      return source if source.is_a?(Result)
      return Support.refuse("destination_id") if source.is_a?(TfdCase) && source.transport_destination_id != destination.id

      companion = form[:companion]
      if companion
        rule = CompanionRule.check(patient: patient, on: trip.date, origin: form[:origin], tfd_case: source,
                                   reason: companion[:reason])
        return Support.refuse_with(rule, "companion") unless rule == :ok
      end

      insert(trip, form, patient, stop, destination, source, by)
    end

    def insert(trip, form, patient, stop, destination, source, by)
      TransportTrip.transaction(requires_new: true) do
        trip.lock!
        next Result.fail(:trip_not_open) unless Catalog::OPEN_STATUSES.include?(trip.status)
        next already_on_trip if TransportTripPassenger.active.exists?(transport_trip_id: trip.id, patient_id: patient.id)

        full = capacity_problems(trip, form)
        next Support.failure(full) if full.any?

        passenger = TransportTripPassenger.create!(row(trip, form, patient, stop, destination, source, by))
        DomainEvents.publish("transport.passenger_added", trip_id: trip.id, passenger_id: passenger.id)
        Result.ok(passenger: passenger)
      end
    rescue ActiveRecord::RecordNotUnique
      already_on_trip
    end

    def already_on_trip = Support.refuse_with(:patient_already_on_trip, "patient_id")

    def row(trip, form, patient, stop, destination, source, by)
      companion = form[:companion]
      key = ORIGIN_KEYS[form[:origin]]
      { transport_trip: trip, patient: patient, transport_trip_stop: stop, transport_destination: destination, origin: form[:origin],
        exception_reason: form[:exception_reason], exception_note: form[:exception_note],
        provider_name: form.key?(:provider_name) ? form[:provider_name] : default_provider(source),
        address: form[:address], appointment_at: form[:appointment_at] || default_appointment(source),
        takes_seat: form[:takes_seat], wheelchair: form[:wheelchair],
        companion_name: companion&.dig(:name), companion_document: companion&.dig(:document), companion_reason: companion&.dig(:reason),
        companion_attendance: (companion ? "pending" : nil), added_by_user: by }
        .merge(key ? { key => source } : {})
    end

    # Desvio 3: o que já está ativo + este passageiro (assento) + o acompanhante.
    def capacity_problems(trip, form)
      paths = { "seats_full" => "takes_seat", "wheelchair_full" => "wheelchair" }
      Occupancy.shortfall(trip, takes_seat: form[:takes_seat], wheelchair: form[:wheelchair], companion: form[:companion].present?)
               .map { |error| { path: paths.fetch(error), error: error } }
    end

    # Desvio 4. -> registro de origem | nil (exceção) | Result de recusa
    def origin_source(form, patient)
      origin = form[:origin]
      return nil if origin == "exception"

      record = find_origin(origin, form[:origin_id])
      return Support.refuse("origin_id") unless record
      return Support.refuse_with(:origin_mismatch, "origin_id") unless owner?(origin, record, patient)
      return Support.refuse("origin_id") unless live?(origin, record)

      record
    end

    def find_origin(origin, id)
      case origin
      when "regulation" then RegulationRequest.find_by(id: id)
      when "appointment" then Appointment.find_by(id: id)
      when "tfd" then TfdCase.find_by(id: id)
      when "series" then TransportSeries.find_by(id: id)
      end
    end

    def owner?(origin, record, patient)
      return Patients::Pairs.of(patient).exists?(id: record.citizen_id) if origin == "appointment"

      record.patient_id == patient.id
    end

    def live?(origin, record)
      case origin
      when "regulation" then REGULATION_STATUSES.include?(record.status)
      when "appointment" then Appointment::LIVE.include?(record.status)
      when "tfd" then TFD_STATUSES.include?(record.status)
      when "series" then record.active_on?(Time.zone.today)
      else true
      end
    end

    def default_appointment(source)
      case source
      when RegulationRequest, Appointment then source.scheduled_at
      when TfdCase then source.appointment_at
      end
    end

    # Só o NOME do prestador cadastrado (care_providers), nunca schedule_place.
    def default_provider(source)
      source.care_provider&.name if source.is_a?(RegulationRequest) || source.is_a?(TfdCase)
    end

    # Forma do corpo -> { problems: [paths], ...campos lidos }
    def shape(attrs)
      problems = []
      form = {}
      %w[patient_id stop_id destination_id].each do |key|
        attrs[key].is_a?(String) && attrs[key].match?(UUID) ? form[key.to_sym] = attrs[key] : problems << key
      end
      %w[takes_seat wheelchair].each do |key|
        Support.boolean?(attrs[key]) ? form[key.to_sym] = attrs[key] : problems << key
      end
      read_origin(attrs, form, problems)
      read_optional_texts(attrs, form, problems)
      read_companion(attrs, form, problems)
      form.merge(problems: problems)
    end

    def read_origin(attrs, form, problems)
      origin = attrs["origin"]
      reason = attrs["exception_reason"]
      origin = "exception" if origin.nil? && !reason.nil?
      return if origin.nil? # origin_required

      return problems << "origin" unless Catalog::ORIGINS.include?(origin)

      form[:origin] = origin
      if origin == "exception"
        Catalog::EXCEPTION_REASONS.include?(reason) ? form[:exception_reason] = reason : problems << "exception_reason"
        note = attrs["exception_note"]
        if note.nil?
          problems << "exception_note" if reason == "other"
        else
          (form[:exception_note] = Support.text(note, Catalog::REASON)) || problems << "exception_note"
        end
        problems << "origin_id" unless attrs["origin_id"].nil?
      else
        problems << "exception_reason" unless reason.nil?
        problems << "exception_note" unless attrs["exception_note"].nil?
        attrs["origin_id"].is_a?(String) && attrs["origin_id"].match?(UUID) ? form[:origin_id] = attrs["origin_id"] : problems << "origin_id"
      end
    end

    def read_optional_texts(attrs, form, problems)
      { "provider_name" => (1..Catalog::TEXT_MAX), "address" => (1..Catalog::ADDRESS_MAX) }.each do |key, range|
        next unless attrs.key?(key)
        next form[key.to_sym] = nil if attrs[key].nil?

        (form[key.to_sym] = Support.text(attrs[key], range)) || problems << key
      end
      return if attrs["appointment_at"].nil?

      at = parse_zoned(attrs["appointment_at"])
      at ? form[:appointment_at] = at : problems << "appointment_at"
    end

    def read_companion(attrs, form, problems)
      raw = attrs["companion"]
      return if raw.nil?
      return problems << "companion" unless raw.is_a?(Hash)

      name = Support.text(raw["name"], Catalog::COMPANION_NAME)
      problems << "companion.name" unless name
      document = raw["document"].nil? ? nil : Support.text(raw["document"], (1..Catalog::COMPANION_DOCUMENT_MAX))
      problems << "companion.document" if !raw["document"].nil? && document.nil?
      reason = raw["reason"].nil? ? nil : Support.text(raw["reason"], Catalog::REASON)
      problems << "companion.reason" if !raw["reason"].nil? && reason.nil?
      form[:companion] = { name: name, document: document, reason: reason }
    end

    def parse_zoned(value)
      return nil unless value.is_a?(String) && value.match?(CareRegulation::ScheduleExternal::ZONED)

      Time.iso8601(value).in_time_zone
    rescue ArgumentError
      nil
    end
  end
end
