module Maintenance
  module Types
    class QueryType < BaseObject
      description "Consultas da API de manutenção"

      field :me, MaintainerType, null: false, description: "O mantenedor da sessão corrente"
      field :maintainers, [ Types::MaintainerType ], null: false,
            description: "Todos os mantenedores, por e-mail. Só sessão humana."
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
      # ADR 0032 (contrato §8): plataforma, sem abrir cidade, sem segredo.
      field :signature_providers, [ Types::SignatureProviderType ], null: false,
            description: "PSC de assinatura do ambiente: credencial presente e última checagem"
      field :signer_status, Types::SignerStatusType, null: false,
            description: "Estado do serviço interno de assinatura (signer)"

      ProviderRow = Data.define(:key, :configured, :last_check_at, :last_check_ok)

      def me = context.fetch(:maintainer)
      def maintainers = Maintainer.order(:email_address)
      def maintenance_tokens = MaintenanceToken.order(created_at: :desc)
      def audit_events(**filters) = AuditEventsQuery.call(**filters)
      def cities(status: nil) = CityCatalogQuery.call(credential: context.fetch(:credential), status: status)

      # R3: só os 5 PSC reais; `configured` é do ambiente, não da cidade.
      def signature_providers
        checks = Signatures::Providers.checks
        Signatures::Providers::CATALOG.map do |key|
          check = checks[key]
          ProviderRow.new(key: key, configured: Signatures::Providers.configured_in_environment?(key),
                          last_check_at: check&.last_check_at, last_check_ok: check&.last_check_ok)
        end
      end

      def signer_status = Signatures::SignerStatus.call

      # O escopo do token é aplicado AQUI (spec §7): é um dos dois pontos em que
      # uma cidade é escolhida, e o único que abre conexão. Slug inexistente
      # responde nulo sem erro; slug fora do escopo responde erro explícito —
      # são coisas diferentes, e confundi-las esconderia a recusa.
      #
      # Fix round 1 (P8, spec §9): a recusa é etiquetada com as mesmas chaves
      # que os analisadores usam (`Analyzers::Refusal::CITY_OUT_OF_SCOPE` +
      # `refusedFields`), para que `GraphqlController#audit_scope_refusal` — o
      # ÚNICO lugar que grava `maintenance.token.refused` — audite esta recusa
      # pelo mesmo caminho, sem um segundo ponto de escrita. O slug PEDIDO
      # nunca entra na etiqueta: é valor de argumento, e o contrato de
      # `Refusal` proíbe isso — só o nome do campo de raiz (`city`) é gravado.
      def city(slug:)
        credential = context.fetch(:credential)
        unless credential.allows_city?(slug)
          raise GraphQL::ExecutionError.new("cidade fora do escopo do token",
                                            extensions: { "code" => Analyzers::Refusal::CITY_OUT_OF_SCOPE,
                                                          Analyzers::Refusal::FIELDS => [ "city" ] })
        end

        City.find_by(slug: slug)
      end
    end
  end
end
