module Maintenance
  module Types
    class MedicationCatalogReleaseType < BaseObject
      description "Release ativa do catálogo de medicamentos (CATMAT 6505; ADR 0033)"

      field :id, ID, null: false
      field :imported_at, GraphQL::Types::ISO8601DateTime, null: false
      field :items_count, Integer, null: false
      field :hidden_count, Integer, null: false
    end
  end
end
