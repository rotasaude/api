module Maintenance
  module Types
    class ReportSnapshotType < BaseObject
      description "Relatório congelado de uma triage, só metadado. " \
                   "`payload`, `outcome`, `signature` e `token` são conteúdo/segredo — nunca saem daqui."

      field :id, ID, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false
      field :expires_at, GraphQL::Types::ISO8601DateTime, null: true
    end
  end
end
