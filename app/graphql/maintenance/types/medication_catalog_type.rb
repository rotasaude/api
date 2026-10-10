# Catálogo de medicamentos da plataforma (contrato §8): sem cidade, sem dado de pessoa.
module Maintenance
  module Types
    class MedicationCatalogType < BaseObject
      description "Catálogo de medicamentos da plataforma (ADR 0033)"

      field :current_release, MedicationCatalogReleaseType, null: true
      field :review_items, [ MedicationCatalogItemType ], null: false do
        argument :first, Integer, required: false, default_value: 50
      end

      def current_release = MedicationCatalogRelease.current

      def review_items(first:)
        MedicationCatalogItem.where(parse_status: "review", status: "active").order(:catmat_code).limit(first.clamp(1, 200))
      end
    end
  end
end
