module Maintenance
  module Types
    class SncrStatusType < BaseObject
      description "SNCR da Anvisa no ambiente (ADR 0034; contrato §8): credencial presente, última conversa real e se " \
                  "o SNCR simulado existe aqui. Nunca segredo, endereço ou CNPJ."

      field :configured, Boolean, null: false
      field :reachable, Boolean, null: false
      field :last_check_at, GraphQL::Types::ISO8601DateTime, null: true
      field :simulated_available, Boolean, null: false
    end
  end
end
