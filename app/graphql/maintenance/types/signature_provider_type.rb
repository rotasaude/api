module Maintenance
  module Types
    class SignatureProviderType < BaseObject
      description "PSC de assinatura em nuvem da plataforma (ADR 0032; contrato §8): a chave do catálogo, se há " \
                  "credencial no ambiente e a última conversa. Nunca segredo, URL ou resposta do PSC."

      field :key, String, null: false
      field :configured, Boolean, null: false
      field :last_check_at, GraphQL::Types::ISO8601DateTime, null: true
      field :last_check_ok, Boolean, null: true
    end
  end
end
