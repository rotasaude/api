module Maintenance
  module Types
    class MaintainerType < BaseObject
      description "Uma conta da API de manutenção"

      field :id, ID, null: false
      field :email_address, String, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false
    end
  end
end
