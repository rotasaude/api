module Maintenance
  module Types
    # Módulo 27b (Q9, Q16): ambiente e situação do envio à BNAFAR da cidade. O
    # objeto é a City já escolhida por QueryType#city_bnafar_status (escopo do
    # token lá); este tipo abre o banco dela, como CityPecConfigType. Só
    # contagens, datas e nomes de domínio.
    class CityBnafarStatusType < BaseObject
      graphql_name "CityBnafarStatus"
      description "Ambiente e situação do envio à BNAFAR da cidade"

      field :environment, String, null: false
      field :environment_editable, Boolean, null: false,
            description: "Só fora de produção o ambiente se troca"
      field :enabled_domains, [ String ], null: false,
            description: "Os domínios com o envio utilizável (a mesma fonte de GET /pharmacy/bnafar/domains)"
      field :alert, Types::BnafarAlertType, null: false
      field :started_on, GraphQL::Types::ISO8601Date, null: true

      def environment = state[:environment]
      def environment_editable = ::Bnafar::Environment.allowed?("homologation", env: Rails.env)
      def started_on = state[:started_on]
      def alert = state[:alert]

      # Interruptores são da plataforma: lidos FORA da transação da cidade (R13).
      def enabled_domains = ::Bnafar::Gate.domains(object)

      private

      def state
        @state ||= begin
          zone = ActiveSupport::TimeZone[object.time_zone] || Time.zone
          due = ::Bnafar::Gate.domains_through(object, Time.current.in_time_zone(zone).to_date - 1)
          read do
            environment = ::Bnafar::Environment.current
            { environment: environment,
              started_on: BnafarSetting.find_by(id: 1)&.started_on,
              alert: ::Bnafar::Alert.call(environment: environment, now: Time.current, domains: due) }
          end
        end
      end

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
