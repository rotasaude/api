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
      field :cities, [ Types::CitySummaryType ], null: false,
            description: "Catálogo de cidades, sem abrir conexão com nenhuma delas" do
        argument :status, Types::CityStatusEnum, required: false
      end
      field :city, Types::CityType, null: true,
            description: "Uma cidade. Único caminho para dentro do banco dela." do
        argument :slug, String, required: true
      end

      def me = context.fetch(:maintainer)
      def maintenance_tokens = MaintenanceToken.order(created_at: :desc)
      def audit_events(**filters) = AuditEventsQuery.call(**filters)
      def cities(status: nil) = CityCatalogQuery.call(credential: context.fetch(:credential), status: status)

      # O escopo do token é aplicado AQUI (spec §7): é um dos dois pontos em que
      # uma cidade é escolhida, e o único que abre conexão. Slug inexistente
      # responde nulo sem erro; slug fora do escopo responde erro explícito —
      # são coisas diferentes, e confundi-las esconderia a recusa.
      def city(slug:)
        credential = context.fetch(:credential)
        unless credential.allows_city?(slug)
          raise GraphQL::ExecutionError.new("cidade fora do escopo do token",
                                            extensions: { "code" => "CITY_OUT_OF_SCOPE" })
        end

        City.find_by(slug: slug)
      end
    end
  end
end
