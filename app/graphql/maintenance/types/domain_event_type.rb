module Maintenance
  module Types
    class DomainEventType < BaseObject
      description "Evento de domínio da cidade, só metadado — o `payload` é dado de cidadão e nunca sai daqui."

      field :name, String, null: false
      field :occurred_at, GraphQL::Types::ISO8601DateTime, null: false
      field :published_at, GraphQL::Types::ISO8601DateTime, null: true
    end
  end
end
