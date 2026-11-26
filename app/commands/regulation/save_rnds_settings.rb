# Grava as configurações do envio da regulação à RNDS (módulo 26c; contrato §5,
# Q13): o caráter por cor, o SIGTAP por especialidade e o envio dos pedidos
# regulados pelo estado. Concorrência otimista: `expected_version` (ausente →
# expected_version_required; diferente da gravada → rnds_settings_changed).
# Sem mudança não sobe a versão nem publica evento; o evento leva só user_id.
module Regulation
  module SaveRndsSettings
    PATH_MAX = 64

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(settings:) |
    # fail(:expected_version_required) | fail(:rnds_settings_changed) |
    # fail(:invalid_priority | :invalid_sigtap | :invalid_cbo | :invalid_request, details: { path: }).
    def call(attrs:, by:, today: Time.zone.today)
      attrs = attrs.to_h.stringify_keys
      version = attrs["expected_version"]
      return Result.fail(:expected_version_required) if version.nil?
      return refuse(:invalid_request, "expected_version") unless version.is_a?(Integer)

      priorities = priorities_from(attrs["priority_by_color"])
      return priorities if priorities.is_a?(Result)

      sigtap = sigtap_from(attrs["specialty_sigtap"], today)
      return sigtap if sigtap.is_a?(Result)
      return refuse(:invalid_request, "send_external") unless [ true, false ].include?(attrs["send_external"])

      RegulationRndsSetting.transaction do
        setting = RegulationRndsSetting.current
        setting.lock!
        next Result.fail(:rnds_settings_changed) if setting.version != version

        changed = setting.priority_by_color != priorities || setting.specialty_sigtap != sigtap ||
                  setting.send_external != attrs["send_external"]
        next Result.ok(settings: setting) unless changed

        setting.update!(priority_by_color: priorities, specialty_sigtap: sigtap, send_external: attrs["send_external"],
                        version: setting.version + 1, updated_at: Time.current, updated_by_user_id: by.id)
        DomainEvents.publish("regulation_rnds.settings_changed", user_id: by.id)
        Result.ok(settings: setting)
      end
    end

    # As quatro cores, cada uma com um valor de PRIORITIES.
    def priorities_from(value)
      return refuse(:invalid_request, "priority_by_color") unless value.is_a?(Hash)

      value = value.to_h.stringify_keys
      return refuse(:invalid_request, "priority_by_color") if (value.keys - CareRegulation::Catalog::COLORS).any?

      CareRegulation::Catalog::COLORS.each do |color|
        return refuse(:invalid_priority, "priority_by_color.#{color}") unless RndsCatalog::PRIORITIES.include?(value[color])
      end
      value.slice(*CareRegulation::Catalog::COLORS)
    end

    # CBO (6 dígitos) => SIGTAP regulável e vigente.
    def sigtap_from(value, today)
      return refuse(:invalid_request, "specialty_sigtap") unless value.is_a?(Hash)

      value = value.to_h.stringify_keys
      return refuse(:invalid_request, "specialty_sigtap") if value.size > RndsLimits::SPECIALTY_SIGTAP_MAX

      value.each do |cbo, code|
        path = "specialty_sigtap.#{cbo.to_s[0, PATH_MAX]}"
        return refuse(:invalid_cbo, path) unless cbo.match?(CareRegulation::Catalog::SPECIALTY_CODE)
        return refuse(:invalid_sigtap, path) if CareRegulation::Targets.resolve(type: "procedure", code: code, on: today).failure?
      end
      value
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })

    private_class_method :priorities_from, :sigtap_from, :refuse
  end
end
