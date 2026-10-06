module Maintenance
  module Types
    # ADR 0028 (contratos §3). enabled/changedAt/changedBy vêm da plataforma;
    # usable/missing leem a cidade e degradam para false/["city_unreachable"].
    class CityFeatureType < BaseObject
      graphql_name "CityFeature"
      description "Interruptor de funcionalidade de uma cidade"

      field :key, String, null: false
      field :description, String, null: false
      field :enabled, Boolean, null: false
      field :usable, Boolean, null: false
      field :missing, [ String ], null: false
      field :changed_at, GraphQL::Types::ISO8601DateTime, null: true
      field :changed_by, String, null: true
    end
  end
end
