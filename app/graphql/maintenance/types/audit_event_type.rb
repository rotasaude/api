module Maintenance
  module Types
    class AuditEventType < BaseObject
      description "Um registro da auditoria de manutenção"

      field :name, String, null: false
      field :module, String, null: false, method: :module_name
      field :outcome, String, null: false
      field :occurred_at, GraphQL::Types::ISO8601DateTime, null: false
      field :maintainer_id, ID, null: true
      field :login, String, null: true, description: "Resolvido na leitura: o evento guarda id, nunca e-mail"
      field :correlation_id, String, null: true
    end
  end
end
