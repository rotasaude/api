module Maintenance
  module Types
    class CityStatusEnum < GraphQL::Schema::Enum
      graphql_name "CityStatus"
      City::STATUSES.each { |status| value status.upcase, value: status }
    end

    class CitySummaryType < BaseObject
      description "Uma cidade do catálogo. Nada aqui vem do banco da cidade."

      field :slug, String, null: false
      field :name, String, null: false
      field :uf, String, null: false
      field :status, String, null: false
      field :schema_version, String, null: true
      field :schema_behind, Boolean, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false

      def schema_behind = CitySchema.behind?(object)
    end
  end
end
