# Parâmetros da sala de vacina da cidade (ADR 0047, Desvio 10): a data do
# go-live, `go_live_on` ("YYYY-MM-DD" ou nulo). Chave desconhecida ou ausente,
# ou data inválida → `invalid_request` com o path (nada é gravado). Data fora
# de [hoje − 2 anos, hoje + 1 ano] no dia da cidade → `out_of_range` (ruling da
# revisão final: uma data digitada errada geraria conferências
# `born_after_go_live` irreversíveis em massa). Uma troca publica
# `vaccination.settings_changed` só com ids (nunca a data).
module Vaccination
  module SaveSettings
    KEY = "go_live_on".freeze
    KEY_PATH_MAX = 64
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/
    PAST_MONTHS = 24
    FUTURE_MONTHS = 12

    module_function

    # -> Result.ok(settings: { "go_live_on" => "2026-11-02"|nil }) | fail(:invalid_request | :out_of_range, details: { path:, problems: })
    def call(attrs:, by:, today: Time.zone.today)
      attrs = attrs.to_h.stringify_keys
      unknown = attrs.keys.find { |key| key != KEY }
      return refuse(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return refuse(KEY) unless attrs.key?(KEY)

      value = attrs[KEY]
      date = value.nil? ? nil : parse(value)
      return refuse(KEY) unless value.nil? || date
      return refuse(KEY, :out_of_range) if date && !date.between?(today << PAST_MONTHS, today >> FUTURE_MONTHS)

      VaccinationSetting.transaction(requires_new: true) do
        setting = VaccinationSetting.current
        setting.lock!
        if setting.go_live_on != date
          setting.update!(go_live_on: date, updated_by_user: by)
          DomainEvents.publish("vaccination.settings_changed", vaccination_setting_id: setting.id, user_id: by.id)
        end
        Result.ok(settings: Json.settings(setting))
      end
    end

    def parse(value)
      return nil unless value.is_a?(String) && value.match?(ISO_DATE)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    def refuse(path, reason = :invalid_request)
      Result.fail(reason, details: { path: path, problems: [ { path: path, error: reason.to_s } ] })
    end
    private_class_method :parse, :refuse
  end
end
