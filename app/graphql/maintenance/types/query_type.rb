module Maintenance
  module Types
    class QueryType < BaseObject
      description "Consultas da API de manutenção"

      field :me, MaintainerType, null: false, description: "O mantenedor da sessão corrente"
      field :maintenance_tokens, [ Types::MaintenanceTokenType ], null: false,
            description: "Tokens de serviço, metadado apenas"

      def me = context.fetch(:maintainer)
      def maintenance_tokens = MaintenanceToken.order(created_at: :desc)
    end
  end
end
