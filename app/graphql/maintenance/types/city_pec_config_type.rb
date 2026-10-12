module Maintenance
  module Types
    # ADR 0035 (contrato §6): a configuração do PEC sem a chave — só se há uma e quando mudou.
    # O objeto é a City já escolhida por QueryType#city_pec_config (escopo do
    # token lá); este tipo é quem abre o banco dela, como CityType, numa só
    # leitura por objeto.
    class CityPecConfigType < BaseObject
      graphql_name "CityPecConfig"
      description "Endereço do PEC e estado da chave HMAC dos sistemas externos (a chave nunca sai)"

      field :pec_origin, String, null: true
      field :hmac_key_configured, Boolean, null: false
      field :hmac_key_updated_at, GraphQL::Types::ISO8601DateTime, null: true

      def pec_origin = config[:pec_origin]
      def hmac_key_configured = config[:hmac_key_configured]
      def hmac_key_updated_at = config[:hmac_key_updated_at]

      private

      def config
        @config ||= read do
          setting = PecSetting.current
          { pec_origin: setting&.pec_origin, hmac_key_configured: setting&.hmac_key_configured? || false,
            hmac_key_updated_at: setting&.hmac_key_updated_at }
        end
      end

      # Igual a CityType#inside: as três falhas previstas viram erro de campo.
      def read(&block)
        CityReader.call(object, &block)
      rescue CityReader::Archived => e
        raise GraphQL::ExecutionError.new(e.message, extensions: { "code" => "CITY_ARCHIVED" })
      rescue CityReader::Unreachable => e
        raise GraphQL::ExecutionError.new(e.message, extensions: { "code" => "CITY_UNREACHABLE" })
      rescue CityReader::Failed => e
        raise GraphQL::ExecutionError.new(e.message, extensions: { "code" => "CITY_READ_FAILED" })
      end
    end
  end
end
