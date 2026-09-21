module Maintenance
  module Types
    class MaintainerType < BaseObject
      description "Uma conta da API de manutenção"

      field :id, ID, null: false
      field :email_address, String, null: false
      field :active, Boolean, null: false, description: "Falso depois de desativado"
      field :enrolled, Boolean, null: false, description: "Senha e TOTP definidos pelo convite"
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false

      def active = object.active?
      def enrolled = object.enrolled?
    end
  end
end
