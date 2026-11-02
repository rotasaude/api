# Parâmetros da sala de vacina da cidade (ADR 0047, Desvio 10): a data do
# go-live, `go_live_on` ("YYYY-MM-DD" ou nulo). Chave desconhecida ou ausente,
# ou data inválida → `invalid_request` com o path (nada é gravado).
module Vaccination
  module SaveSettings
    KEY = "go_live_on".freeze
    KEY_PATH_MAX = 64
    ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

    module_function

    # -> Result.ok(settings: { "go_live_on" => "2026-11-02"|nil }) | fail(:invalid_request, details: { path: })
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      unknown = attrs.keys.find { |key| key != KEY }
      return refuse(unknown.to_s[0, KEY_PATH_MAX]) if unknown
      return refuse(KEY) unless attrs.key?(KEY)

      value = attrs[KEY]
      date = value.nil? ? nil : parse(value)
      return refuse(KEY) unless value.nil? || date

      VaccinationSetting.transaction(requires_new: true) do
        setting = VaccinationSetting.current
        setting.lock!
        if setting.go_live_on != date
          setting.update!(go_live_on: date, updated_by_user: by)
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

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :parse, :refuse
  end
end
