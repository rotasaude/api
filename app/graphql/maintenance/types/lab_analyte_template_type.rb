module Maintenance
  module Types
    class LabAnalyteTemplateType < BaseObject
      graphql_name "LabAnalyteTemplate"

      field :id, ID, null: false
      field :key, String, null: false
      field :name, String, null: false
      field :loinc, String, null: true
      field :unit, String, null: true
      field :value_type, String, null: false
      field :choices, [ String ], null: false
      field :decimals, Int, null: false
      field :position, Int, null: false
      field :reference_ranges, [ Types::LabReferenceRangeType ], null: false
    end
  end
end
