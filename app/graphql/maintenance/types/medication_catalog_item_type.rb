module Maintenance
  module Types
    class MedicationCatalogItemType < BaseObject
      description "Item do catálogo em revisão (o analisador não entendeu a descrição)"

      field :catmat_code, Integer, null: false
      field :source_description, String, null: false
      field :parse_status, String, null: false
    end
  end
end
