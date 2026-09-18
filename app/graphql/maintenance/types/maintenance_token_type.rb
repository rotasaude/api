module Maintenance
  module Types
    class MaintenanceTokenType < BaseObject
      description "Metadado de um token de serviço. O segredo NUNCA aparece aqui."

      field :id, ID, null: false
      # M2 (fix round 2): o tipo não dizia de QUEM é o token, e a listagem
      # mostra os de todo mundo. Sem o dono, quem opera a tela não tem como
      # saber o que está revogando — e revogar aceita qualquer id.
      field :maintainer_id, ID, null: false
      field :name, String, null: false
      field :access, String, null: false
      field :city_slugs, [ String ], null: false
      field :expires_at, GraphQL::Types::ISO8601DateTime, null: false
      field :revoked_at, GraphQL::Types::ISO8601DateTime, null: true
      field :last_used_at, GraphQL::Types::ISO8601DateTime, null: true
    end
  end
end
