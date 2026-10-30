# Parâmetros da farmácia da cidade (ADR 0045; contrato §3): as cinco chaves,
# todas obrigatórias, inteiros dentro de `SETTING_RANGES`. Qualquer chave fora
# da lista, ausente, que não seja inteiro JSON ou fora da faixa → `invalid_request`
# com `path` da chave e `problems` (nada é gravado). Evento `pharmacy.settings_changed`
# (subject `settings`) só com ids, e só quando algum valor muda.
module Pharmacy
  module SaveSettings
    KEY_PATH_MAX = 64

    module_function

    # attrs: corpo JSON (chaves texto). -> Result.ok(settings: { "common_validity_days" => 30, … }) |
    # fail(:invalid_request, details: { path: "<chave>" }).
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      unknown = attrs.keys.find { |key| Catalog::SETTING_RANGES.exclude?(key) }
      return refuse(unknown.to_s[0, KEY_PATH_MAX]) if unknown

      Catalog::SETTING_RANGES.each do |key, range|
        value = attrs[key]
        return refuse(key) unless value.is_a?(Integer) && range.cover?(value)
      end

      PharmacySetting.transaction(requires_new: true) do
        setting = PharmacySetting.current
        setting.lock!
        new_values = attrs.slice(*Catalog::SETTING_RANGES.keys)
        if Json.settings(setting) != new_values
          setting.assign_attributes(new_values)
          setting.updated_by_user = by
          setting.save!
          DomainEvents.publish("pharmacy.settings_changed", subject: "settings", user_id: by.id)
        end
        Result.ok(settings: Json.settings(setting))
      end
    end

    # Todo 422 traz `problems` com ao menos um problema (regra do módulo).
    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
