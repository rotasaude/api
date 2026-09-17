module Maintenance
  module Types
    class QueryType < BaseObject
      description "Consultas da API de manutenção"

      field :me, MaintainerType, null: false, description: "O mantenedor da sessão corrente"
      field :maintenance_tokens, [ Types::MaintenanceTokenType ], null: false,
            description: "Tokens de serviço, metadado apenas"
      field :audit_events, [ Types::AuditEventType ], null: false,
            description: "Auditoria de manutenção, só para sessão humana" do
        argument :since, GraphQL::Types::ISO8601DateTime, required: false
        # `until` e `module` são palavras reservadas do Ruby: o nome público
        # continua o da spec, e o `as:` dá ao resolver um kwarg utilizável.
        argument :until, GraphQL::Types::ISO8601DateTime, required: false, as: :until_time
        argument :maintainer_id, ID, required: false
        argument :module, String, required: false, as: :module_filter
        argument :outcome, String, required: false
        argument :limit, Integer, required: false
      end

      def me = context.fetch(:maintainer)
      def maintenance_tokens = MaintenanceToken.order(created_at: :desc)
      def audit_events(**filters) = AuditEventsQuery.call(**filters)
    end
  end
end
