module Maintenance
  module Mutations
    class PublishProtocol < CityMutation
      description "Publica uma versão em revisão. Exige duas assinaturas de revisores da cidade que " \
                  "não a editaram, e o TOTP do momento."

      argument :name, String, required: true
      argument :version, Integer, required: true
      argument :code, String, required: true, description: "TOTP do momento"

      def resolve(city_slug:, name:, version:, code:)
        in_city(city_slug: city_slug, step_up_code: code, event: "maintenance.protocol.published", module_name: "protocol",
                protocol_key: name, version: version, changed_fields: [ "status" ]) do |actor, correlation_id|
          Protocols::Publish.call(version: version, name: name, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
