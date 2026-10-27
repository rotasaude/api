module Maintenance
  module Types
    class NotifiableDiseaseInput < GraphQL::Schema::InputObject
      graphql_name "NotifiableDiseaseInput"

      argument :code, String, required: true
      argument :name, String, required: true
      argument :deadline, String, required: true
      argument :cid10, [ String ], required: true
      argument :ciap2, [ String ], required: true
      argument :repeat_after_days, Integer, required: true
      argument :sinan_form, String, required: false
      argument :notes, String, required: false
      argument :sources, GraphQL::Types::JSON, required: true
    end
  end
end
