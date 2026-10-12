module Maintenance
  module Types
    # ADR 0035 (contrato §6): a configuração do PEC sem a chave — só se há uma e quando mudou.
    class CityPecConfigType < BaseObject
      graphql_name "CityPecConfig"
      description "Endereço do PEC e estado da chave HMAC dos sistemas externos (a chave nunca sai)"

      field :pec_origin, String, null: true
      field :hmac_key_configured, Boolean, null: false
      field :hmac_key_updated_at, GraphQL::Types::ISO8601DateTime, null: true
    end
  end
end
