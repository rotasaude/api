module Maintenance
  module Mutations
    class SubmitProtocolForReview < CityMutation
      description "Envia um rascunho para revisão: a partir daqui revisores da cidade podem assinar."

      argument :name, String, required: true
      argument :version, Integer, required: true

      def resolve(city_slug:, name:, version:)
        in_city(city_slug: city_slug, event: "maintenance.protocol.submitted", module_name: "protocol",
                protocol_key: name, version: version, changed_fields: [ "status" ]) do |actor, correlation_id|
          Protocols::SubmitForReview.call(name: name, version: version, by: actor, correlation_id: correlation_id)
        end
      end
    end
  end
end
