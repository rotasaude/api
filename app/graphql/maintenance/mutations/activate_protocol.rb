module Maintenance
  module Mutations
    class ActivateProtocol < CityMutation
      description "Ativa uma versão publicada como a vigente da cidade. Exige duas assinaturas de " \
                  "ativação de revisores da cidade e o TOTP do momento."

      argument :name, String, required: true
      argument :version, Integer, required: true
      argument :code, String, required: true, description: "TOTP do momento"

      def resolve(city_slug:, name:, version:, code:)
        in_city(city_slug: city_slug, event: "maintenance.protocol.activated", module_name: "protocol",
                protocol_key: name, version: version,
                changed_fields: [ "status", "activated_at" ]) do |actor, correlation_id|
          step_up!(code)
          Protocols::Activate.call(version: version, name: name, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
