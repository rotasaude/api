# PATCH /psychosocial/settings (ADR 0049; contrato §3): parcial; todas as
# recusas de campo de uma vez em `problems`. Chave desconhecida → invalid_request
# com o nome; `night_limits` só com modalidades de NIGHT_MODALITIES, cada uma
# com a forma inteira da sua regra (CAPS III: consecutive, alternate,
# window_days; AD III/IV: total, window_days) e substitui a da modalidade;
# `care_plan_review_days` em REVIEW_DAYS. Uma troca publica
# `psychosocial.settings_changed`, sem payload (contrato §13).
module Psychosocial
  module SaveSettings
    KEY_PATH_MAX = 64
    KEYS = %w[night_limits care_plan_review_days].freeze

    module_function

    # attrs: corpo JSON. -> Result.ok(settings: <forma do §3>) | fail(:invalid_request, details: { path:, problems: })
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      unknown = attrs.keys.find { |key| KEYS.exclude?(key) }
      return failure([ problem(unknown.to_s[0, KEY_PATH_MAX]) ]) if unknown

      problems = []
      changes = {}
      validate_review_days(attrs, changes, problems)
      validate_night_limits(attrs, changes, problems)
      return failure(problems) if problems.any?

      PsychosocialSetting.transaction(requires_new: true) do
        setting = Settings.current
        setting.lock!
        changes["night_limits"] = setting.night_limits.merge(changes["night_limits"]) if changes.key?("night_limits")
        setting.assign_attributes(changes)
        if setting.changed?
          setting.updated_by_user = by
          setting.save!
          DomainEvents.publish("psychosocial.settings_changed")
        end
        Result.ok(settings: Settings.json(setting))
      end
    end

    def validate_review_days(attrs, changes, problems)
      return unless attrs.key?("care_plan_review_days")

      value = attrs["care_plan_review_days"]
      return problems << problem("care_plan_review_days") unless value.is_a?(Integer) && Catalog::REVIEW_DAYS.cover?(value)

      changes["care_plan_review_days"] = value
    end

    def validate_night_limits(attrs, changes, problems)
      return unless attrs.key?("night_limits")

      limits = attrs["night_limits"]
      return problems << problem("night_limits") unless limits.is_a?(Hash) && limits.any?

      accepted = {}
      limits.each do |modality, rule|
        path = "night_limits.#{modality.to_s[0, KEY_PATH_MAX]}"
        keys = Catalog::NIGHT_LIMIT_KEYS[modality.to_s]
        next problems << problem(path) unless keys && HealthUnit::NIGHT_MODALITIES.include?(modality.to_s)
        next problems << problem(path) unless rule.is_a?(Hash) && rule.keys.map(&:to_s).sort == keys

        bad = rule.filter_map do |key, value|
          range = key.to_s == "window_days" ? Catalog::WINDOW_DAYS : Catalog::NIGHT_COUNT
          "#{path}.#{key}" unless value.is_a?(Integer) && range.cover?(value)
        end
        next problems.concat(bad.map { |p| problem(p) }) if bad.any?

        accepted[modality.to_s] = rule.to_h { |key, value| [ key.to_s, value ] }
      end
      changes["night_limits"] = accepted if accepted.size == limits.size
    end

    def problem(path, error = "invalid_request") = { path: path, error: error }

    def failure(problems)
      first = problems.first
      Result.fail(first[:error].to_sym, details: { path: first[:path], problems: problems })
    end

    private_class_method :validate_review_days, :validate_night_limits, :problem, :failure
  end
end
