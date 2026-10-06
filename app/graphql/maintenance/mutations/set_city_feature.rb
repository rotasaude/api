module Maintenance
  module Mutations
    # ADR 0028 (contratos §3): o maintenance é a única porta que liga e desliga
    # interruptores. Escreve na plataforma (on_platform), sem abrir a cidade.
    class SetCityFeature < CityMutation
      description "Liga ou desliga um interruptor de funcionalidade da cidade."

      argument :key, String, required: true
      argument :enabled, Boolean, required: true

      field :feature, Types::CityFeatureType, null: true

      def resolve(city_slug:, key:, enabled:)
        on_platform(city_slug: city_slug, event: "maintenance.city.feature_changed", module_name: "city",
                    field_paths: { feature_key: "key", enabled: "enabled" }, feature_key: key, enabled: enabled,
                    payload_from_result: ->(result) { { feature: result.payload[:feature] } }) do |city, actor, _id|
          Platform::Features.set!(city: city, key: key, enabled: enabled, maintainer: actor.maintainer)
          Result.ok(feature: Platform::Features.summary(city).find { |row| row[:key] == key })
        end
      end
    end
  end
end
