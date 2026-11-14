module Maintenance
  module Types
    # ADR 0053 (contrato do 24c §10; Q21, Q30): a linha `field_maps` de uma
    # cidade. `state` e `errorCode` são os da última geração; `version`,
    # `sizeBytes` e `builtAt` são os do arquivo publicado (nulos sem ele), que
    # segue servido enquanto a geração nova roda ou falha.
    class FieldMapType < BaseObject
      description "Mapa offline de campo de uma cidade (recorte do OpenStreetMap; sem dado de pessoa)"

      field :city_slug, String, null: false
      field :state, String, null: false
      field :version, GraphQL::Types::ISO8601Date, null: true
      field :size_bytes, GraphQL::Types::BigInt, null: true
      field :built_at, GraphQL::Types::ISO8601DateTime, null: true
      field :error_code, String, null: true

      def city_slug = object.city.slug
    end
  end
end
