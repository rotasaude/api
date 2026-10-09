module Maintenance
  module Types
    class SignerStatusType < BaseObject
      description "Serviço interno signer (ADR 0032; contrato §8): alcançável, versão e última atualização das LCRs."

      field :reachable, Boolean, null: false
      field :version, String, null: true
      field :crl_updated_at, GraphQL::Types::ISO8601DateTime, null: true
    end
  end
end
