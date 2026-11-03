# Cadastra e edita veículos da frota (ADR 0048; Valores fixados 3; T18/T19).
# Placa sem hífen e em maiúsculas (Mercosul ou antiga), RENAVAM de 11 dígitos,
# modelo 2–80, tipo da lista, lugares 1–60, vagas de cadeirante 0–10, CNES
# opcional de 7 dígitos. Todas as recusas de campo de uma vez; placa e RENAVAM
# únicos (409). Nunca se apaga: desativa-se (`active`). Evento só com ids.
module Transport
  module SaveVehicle
    KEYS = %w[plate renavam model kind renem_code seats wheelchair_spots cnes active].freeze

    module_function

    # -> Result.ok(vehicle:) | fail(:invalid_request, details: { path:, problems: }) |
    # fail(:plate_taken) | fail(:renavam_taken)
    def call(attrs:, by:, record: nil)
      attrs = attrs.to_h.stringify_keys.slice(*KEYS)
      values = record ? current(record).merge(attrs) : { "active" => true, "wheelchair_spots" => 0 }.merge(attrs)
      clean, bad = validate(values)
      return Support.refuse(bad) if bad.any?

      TransportVehicle.transaction(requires_new: true) do
        vehicle = record || TransportVehicle.new
        vehicle.lock! if record
        vehicle.assign_attributes(clean)
        next Result.ok(vehicle: vehicle) if record && !vehicle.changed?

        vehicle.updated_by_user = by
        vehicle.save!
        DomainEvents.publish("transport.vehicle_saved", vehicle_id: vehicle.id, user_id: by.id)
        Result.ok(vehicle: vehicle)
      end
    rescue ActiveRecord::RecordNotUnique => e
      Result.fail(e.message.include?("idx_transport_vehicles_renavam") ? :renavam_taken : :plate_taken)
    end

    def current(record)
      record.attributes.slice(*KEYS)
    end

    # -> [valores limpos, caminhos recusados] (em edição os valores atuais já são válidos).
    def validate(values)
      clean = {}
      bad = []
      check = lambda do |key, value|
        if value.nil? && !(key == "cnes" || key == "renem_code") then bad << key
        else clean[key] = value
        end
      end
      plate = values["plate"].is_a?(String) ? values["plate"].delete("-").strip.upcase : nil
      check.call("plate", plate&.match?(Catalog::PLATE) ? plate : nil)
      renavam = values["renavam"].is_a?(String) ? values["renavam"].strip : nil
      check.call("renavam", renavam&.match?(Catalog::RENAVAM) ? renavam : nil)
      check.call("model", Support.text(values["model"], Catalog::MODEL))
      check.call("kind", Catalog::VEHICLE_KINDS.include?(values["kind"]) ? values["kind"] : nil)
      check.call("seats", Support.integer(values["seats"], Catalog::SEATS))
      check.call("wheelchair_spots", Support.integer(values["wheelchair_spots"], Catalog::WHEELCHAIR_SPOTS))
      check.call("active", Support.boolean?(values["active"]) ? values["active"] : nil)
      optional(clean, bad, "cnes", values["cnes"]) { |v| v.is_a?(String) && v.match?(Catalog::CNES) }
      optional(clean, bad, "renem_code", values["renem_code"]) { |v| v.is_a?(String) && v.strip.length.between?(1, Catalog::RENEM_MAX) }
      clean["renem_code"] = clean["renem_code"]&.strip
      [ clean, bad.uniq ]
    end

    def optional(clean, bad, key, value)
      if value.nil? then clean[key] = nil
      elsif yield(value) then clean[key] = value
      else bad << key
      end
    end

    private_class_method :current, :validate, :optional
  end
end
