module Maintenance
  module Mutations
    class RetireProtocol < CityMutation
      description "Aposenta uma versão de protocolo. A versão active da cidade nunca é aposentada (R4). " \
                  "Exige o TOTP do momento."

      argument :name, String, required: true
      argument :version, Integer, required: true
      argument :code, String, required: true, description: "TOTP do momento"

      def resolve(city_slug:, name:, version:, code:)
        in_city(city_slug: city_slug, event: "maintenance.protocol.retired", module_name: "protocol",
                protocol_key: name, version: version,
                changed_fields: [ "status", "retired_at" ]) do |actor, correlation_id|
          step_up!(code)
          Protocols::Retire.call(version: version, name: name, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
