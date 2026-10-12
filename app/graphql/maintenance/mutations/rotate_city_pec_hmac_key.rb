module Maintenance
  module Mutations
    # ADR 0035 (contrato §6): grava ou troca a chave HMAC do cadastro do
    # integrador no PEC. A chave nunca volta (payload só { ok, errors }) e
    # nunca entra na auditoria (só o campo). Step-up pela base (decisão M4).
    class RotateCityPecHmacKey < CityMutation
      description "Grava ou troca a chave HMAC dos sistemas externos do PEC da cidade. A chave nunca volta. " \
                  "Exige o TOTP do momento."

      argument :key, String, required: true
      argument :code, String, required: true, description: "TOTP do momento"

      def resolve(city_slug:, key:, code:)
        outcome = in_city(city_slug: city_slug, step_up_code: code, event: "maintenance.city.pec_config_changed",
                          module_name: "city", rejection_path: "key", pec_field: "hmac_key") do |_actor, _correlation_id|
          PecExternal::Configure.rotate_key(key: key)
        end
        PecExternal::Configure.audit!(city_slug: city_slug, field: "hmac_key", maintainer_id: credential.maintainer.id) if outcome[:ok]
        outcome
      end
    end
  end
end
