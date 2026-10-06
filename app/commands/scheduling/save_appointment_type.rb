# Tipos de atendimento da cidade (ADR 0029 §3.1; contratos §3, §9). Só o
# municipal_admin chega aqui (controller). O tipo da plataforma ajusta nome,
# duração e ativo; os grupos de CBO são da plataforma (platform_type_locked).
module Scheduling
  module SaveAppointmentType
    PREFIX = /\A\d{1,6}\z/
    MAX_NAME = 60
    MAX_PREFIXES = 20

    module_function

    def create(attrs:, by:)
      key = attrs["key"]
      return Result.fail(:invalid_key) unless key.is_a?(String) && key.match?(AppointmentType::KEY)

      values = { "name" => attrs["name"], "duration_minutes" => attrs["duration_minutes"],
                 "cbo_prefixes" => attrs["cbo_prefixes"], "active" => attrs.fetch("active", true) }
      reason = invalid(values)
      return Result.fail(reason) if reason

      type = ApplicationRecord.transaction(requires_new: true) do
        AppointmentType.create!(key: key, name: values["name"].squish, duration_minutes: values["duration_minutes"],
                                cbo_prefixes: values["cbo_prefixes"], active: values["active"], origin: "city")
      end
      DomainEvents.publish("appointment_type.changed", key: type.key, user_id: by.id)
      Result.ok(type: type)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:key_taken)
    end

    def update(type:, attrs:, by:)
      return Result.fail(:platform_type_locked) if type.platform? && attrs.key?("cbo_prefixes")

      values = attrs.slice("name", "duration_minutes", "cbo_prefixes", "active")
      reason = invalid(values)
      return Result.fail(reason) if reason

      changes = values.to_h { |k, v| [ k, k == "name" ? v.squish : v ] }
      ApplicationRecord.transaction do
        type.update!(changes)
        DomainEvents.publish("appointment_type.changed", key: type.key, user_id: by.id)
      end
      Result.ok(type: type)
    end

    # Só confere as chaves presentes (update parcial); create passa todas.
    def invalid(values)
      if values.key?("name")
        name = values["name"]
        return :invalid_name unless name.is_a?(String) && name.squish.length.between?(1, MAX_NAME)
      end
      if values.key?("duration_minutes")
        minutes = values["duration_minutes"]
        return :invalid_duration unless minutes.is_a?(Integer) && minutes.between?(5, 240)
      end
      if values.key?("cbo_prefixes")
        prefixes = values["cbo_prefixes"]
        ok = prefixes.is_a?(Array) && prefixes.size.between?(1, MAX_PREFIXES) &&
             prefixes.all? { |p| p.is_a?(String) && p.match?(PREFIX) }
        return :invalid_cbo_prefixes unless ok
      end
      return :invalid if values.key?("active") && ![ true, false ].include?(values["active"])

      nil
    end
  end
end
