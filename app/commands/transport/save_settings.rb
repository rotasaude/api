# PATCH /transport/admin/settings (contrato §3, T12): parcial; todas as recusas
# de campo de uma vez em `problems`. Chave desconhecida → invalid_request com o
# nome; unidade de faturamento que não é health_management com CNES →
# billing_unit_invalid. Uma troca publica `transport.settings_changed` só com o
# id da cidade e os NOMES das chaves que mudaram, nunca os valores (T27).
module Transport
  module SaveSettings
    KEY_PATH_MAX = 64
    KEYS = %w[tfd_min_distance_km companion_rule tfd_billing_health_unit_id allowance_complements].freeze
    DISTANCE = (1..1000)
    CHILD_AGE = (0..17)
    ELDERLY_AGE = (50..100)
    COMPLEMENT = (0..1_000_000)
    # Coluna → chave do corpo (a regra do acompanhante ocupa duas colunas).
    COLUMN_KEYS = { "tfd_min_distance_km" => "tfd_min_distance_km", "companion_max_age_child" => "companion_rule",
                    "companion_min_age_elderly" => "companion_rule", "tfd_billing_health_unit_id" => "tfd_billing_health_unit_id",
                    "allowance_complements" => "allowance_complements" }.freeze

    module_function

    # attrs: corpo JSON. -> Result.ok(settings: <forma do §3>) | fail(:invalid_request | :billing_unit_invalid, details: { path:, problems: })
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      unknown = attrs.keys.find { |key| KEYS.exclude?(key) }
      return refuse(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      problems = []
      changes = {}
      validate_distance(attrs, changes, problems)
      validate_rule(attrs, changes, problems)
      validate_unit(attrs, changes, problems)
      validate_complements(attrs, changes, problems)
      return failure(problems) if problems.any?

      TransportSetting.transaction(requires_new: true) do
        setting = Settings.current
        setting.lock!
        setting.assign_attributes(changes)
        changed = changed_keys(setting)
        if changed.any?
          setting.updated_by_user = by
          setting.save!
          DomainEvents.publish("transport.settings_changed", city_id: Current.city.id, changed: changed)
        end
        Result.ok(settings: Settings.json(setting))
      end
    end

    def validate_distance(attrs, changes, problems)
      return unless attrs.key?("tfd_min_distance_km")

      value = attrs["tfd_min_distance_km"]
      return problems << problem("tfd_min_distance_km") unless value.is_a?(Integer) && DISTANCE.cover?(value)

      changes["tfd_min_distance_km"] = value
    end

    def validate_rule(attrs, changes, problems)
      return unless attrs.key?("companion_rule")

      rule = attrs["companion_rule"]
      unless rule.is_a?(Hash) && rule.keys.sort == %w[max_age_child min_age_elderly]
        return problems << problem("companion_rule")
      end

      { "max_age_child" => CHILD_AGE, "min_age_elderly" => ELDERLY_AGE }.each do |key, range|
        value = rule[key]
        next problems << problem("companion_rule.#{key}") unless value.is_a?(Integer) && range.cover?(value)

        changes[key == "max_age_child" ? "companion_max_age_child" : "companion_min_age_elderly"] = value
      end
    end

    def validate_unit(attrs, changes, problems)
      return unless attrs.key?("tfd_billing_health_unit_id")

      id = attrs["tfd_billing_health_unit_id"]
      if id.nil?
        changes["tfd_billing_health_unit_id"] = nil
        return
      end
      unit = id.is_a?(String) && id.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) ? HealthUnit.find_by(id: id) : nil
      unless unit && unit.kind == "health_management" && unit.cnes.present?
        return problems << problem("tfd_billing_health_unit_id", "billing_unit_invalid")
      end

      changes["tfd_billing_health_unit_id"] = unit.id
    end

    def validate_complements(attrs, changes, problems)
      return unless attrs.key?("allowance_complements")

      map = attrs["allowance_complements"]
      return problems << problem("allowance_complements") unless map.is_a?(Hash)

      bad = false
      map.each do |code, cents|
        unless Tfd::SigtapCodes.all.include?(code)
          bad = true
          next problems << problem("allowance_complements.#{code.to_s[0, KEY_PATH_MAX]}")
        end
        next if cents.is_a?(Integer) && COMPLEMENT.cover?(cents)

        bad = true
        problems << problem("allowance_complements.#{code}")
      end
      changes["allowance_complements"] = map unless bad
    end

    # Nomes das chaves do corpo (§3) cujos valores mudaram, em ordem alfabética.
    def changed_keys(setting)
      setting.changed.filter_map { |column| COLUMN_KEYS[column] }.uniq.sort
    end

    def problem(path, error = "invalid_request") = { path: path, error: error }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ problem(path) ] })
    private_class_method :validate_distance, :validate_rule, :validate_unit, :validate_complements, :changed_keys, :problem, :failure, :refuse
  end
end
