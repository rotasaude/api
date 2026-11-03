# POST/PATCH /transport/series[/:id] (contrato §4; §14 T6, T18; ADR 0048).
# Corpo `{ patient_id, destination_id, provider_name?, weekdays, appointment_time,
# departure_time, return_time, boarding_label, starts_on, ends_on?, wheelchair,
# companion?: { name, document?, reason? } }`. Dias ISO (1 = segunda … 7 =
# domingo), sem repetição; horas "HH:MM" locais; volta depois da saída
# (`return_before_departure`); fim não antes do início; embarque 3–120. Na
# criação tudo obrigatório, menos prestador, fim, acompanhante e `wheelchair`
# (padrão false); no PATCH só o que veio, e o paciente não troca. Todas as
# recusas de campo de uma vez. Acompanhante pela regra da cidade
# (Transport::CompanionRule) no início da série (ou hoje, se já começou) →
# `companion_not_allowed`: a materialização não pode tropeçar nela. As
# viagens já materializadas não mudam; as próximas seguem a série nova. Nada
# do paciente, do acompanhante nem do destino em Result.details.
module Transport
  module SaveSeries
    KEYS = %w[patient_id destination_id provider_name weekdays appointment_time departure_time return_time boarding_label
              starts_on ends_on wheelchair companion].freeze
    REQUIRED = %w[patient_id destination_id weekdays appointment_time departure_time return_time boarding_label starts_on].freeze
    TIMES = %w[appointment_time departure_time return_time].freeze
    CLOCK = /\A([01]\d|2[0-3]):[0-5]\d\z/
    LABEL = (3..Catalog::TEXT_MAX)
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    # -> Result.ok(series:) | fail(<primeira recusa>, details: { path:, problems: })
    def call(attrs:, by:, series: nil)
      attrs = attrs.to_h.deep_stringify_keys.slice(*KEYS)
      problems = []
      values = read(attrs, series, problems)

      TransportSeries.transaction(requires_new: true) do
        record = series || TransportSeries.new(created_by_user: by, wheelchair: false)
        record.lock! if series
        record.assign_attributes(values)
        refused = problems.map { |problem| problem[:path] }
        problems += rules(record, refused).reject { |problem| refused.include?(problem[:path]) }
        next Support.failure(problems) if problems.any?

        record.save! if record.changed?
        Result.ok(series: record)
      end
    end

    # -> atributos lidos; recusas em `problems` ({ path:, error: }).
    def read(attrs, series, problems)
      values = {}
      bad = ->(path) { problems << { path: path, error: "invalid_request" } }
      REQUIRED.each { |key| bad.call(key) if series.nil? && !attrs.key?(key) }

      if attrs.key?("patient_id")
        patient = uuid(attrs["patient_id"]) && Patient.find_by(id: attrs["patient_id"])
        if patient.nil? || (series && series.patient_id != patient.id) then bad.call("patient_id")
        else values[:patient] = patient
        end
      end
      if attrs.key?("destination_id")
        destination = uuid(attrs["destination_id"]) && TransportDestination.find_by(id: attrs["destination_id"], active: true)
        destination ? values[:transport_destination] = destination : bad.call("destination_id")
      end
      if attrs.key?("weekdays")
        days = attrs["weekdays"]
        ok = days.is_a?(Array) && days.any? && days.all? { |d| d.is_a?(Integer) && d.between?(1, 7) } && days.uniq.size == days.size
        ok ? values[:weekdays] = days.sort : bad.call("weekdays")
      end
      TIMES.each do |key|
        next unless attrs.key?(key)

        attrs[key].is_a?(String) && attrs[key].match?(CLOCK) ? values[key.to_sym] = attrs[key] : bad.call(key)
      end
      if attrs.key?("boarding_label")
        label = Support.text(attrs["boarding_label"], LABEL)
        label ? values[:boarding_label] = label : bad.call("boarding_label")
      end
      read_dates(attrs, values, bad)
      read_optional(attrs, values, bad)
      read_companion(attrs, values, bad)
      values
    end

    def read_dates(attrs, values, bad)
      if attrs.key?("starts_on")
        starts = Support.date(attrs["starts_on"])
        starts ? values[:starts_on] = starts : bad.call("starts_on")
      end
      return unless attrs.key?("ends_on")
      return values[:ends_on] = nil if attrs["ends_on"].nil?

      ends = Support.date(attrs["ends_on"])
      ends ? values[:ends_on] = ends : bad.call("ends_on")
    end

    def read_optional(attrs, values, bad)
      if attrs.key?("provider_name")
        if attrs["provider_name"].nil? then values[:provider_name] = nil
        else
          name = Support.text(attrs["provider_name"], (1..Catalog::TEXT_MAX))
          name ? values[:provider_name] = name : bad.call("provider_name")
        end
      end
      return unless attrs.key?("wheelchair")

      Support.boolean?(attrs["wheelchair"]) ? values[:wheelchair] = attrs["wheelchair"] : bad.call("wheelchair")
    end

    # `companion: null` tira o acompanhante; objeto o substitui inteiro.
    def read_companion(attrs, values, bad)
      return unless attrs.key?("companion")

      raw = attrs["companion"]
      if raw.nil?
        values.merge!(companion_name: nil, companion_document: nil, companion_reason: nil)
        return
      end
      return bad.call("companion") unless raw.is_a?(Hash)

      name = Support.text(raw["name"], Catalog::COMPANION_NAME)
      bad.call("companion.name") unless name
      document = raw["document"].nil? ? nil : Support.text(raw["document"], (1..Catalog::COMPANION_DOCUMENT_MAX))
      bad.call("companion.document") if !raw["document"].nil? && document.nil?
      reason = raw["reason"].nil? ? nil : Support.text(raw["reason"], Catalog::REASON)
      bad.call("companion.reason") if !raw["reason"].nil? && reason.nil?
      values.merge!(companion_name: name, companion_document: document, companion_reason: reason)
    end

    # Regras do registro inteiro (o que veio + o que já havia), junto com as
    # recusas de campo; `refused` são os paths já recusados.
    def rules(record, refused)
      out = []
      if record.return_time && record.departure_time && record.clock(:return_time) <= record.clock(:departure_time)
        out << { path: "return_time", error: "return_before_departure" }
      end
      out << { path: "ends_on", error: "invalid_request" } if record.ends_on && record.starts_on && record.ends_on < record.starts_on
      if record.companion_name && record.patient && record.starts_on && refused.none? { |path| path.start_with?("companion") }
        on = [ record.starts_on, Time.zone.today ].max
        rule = CompanionRule.check(patient: record.patient, on: on, origin: "series", tfd_case: nil, reason: record.companion_reason)
        out << { path: "companion", error: rule.to_s } unless rule == :ok
      end
      out
    end

    def uuid(value) = value.is_a?(String) && value.match?(UUID)

    private_class_method :read, :read_dates, :read_optional, :read_companion, :rules, :uuid
  end
end
