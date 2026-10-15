module Maintenance
  module Types
    class LabReferenceRangeInput < GraphQL::Schema::InputObject
      graphql_name "LabReferenceRangeInput"

      argument :sex, String, required: true
      argument :age_min_days, Int, required: true
      argument :age_max_days, Int, required: true
      argument :low, Float, required: false
      argument :high, Float, required: false
      argument :text, String, required: false
    end
  end
end
