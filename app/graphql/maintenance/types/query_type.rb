module Maintenance
  module Types
    class QueryType < BaseObject
      description "Consultas da API de manutenção"

      # ADR 0037 (contrato §10, M1): catálogo-base do laboratório, plataforma.
      field :lab_exam_templates, [ Types::LabExamTemplateType ], null: false,
            description: "Catálogo-base de exames de laboratório (ativos e inativos, por nome)"
      # ADR 0040 (contrato §8): catálogo-base das linhas de cuidado, plataforma.
      field :care_line_templates, [ Types::CareLineTemplateType ], null: false,
            description: "Versões do catálogo-base das linhas de cuidado (por chave, da mais nova)" do
        argument :key, String, required: false
      end
      # ADR 0043 (módulo 25): lista nacional de notificação compulsória, plataforma.
      field :notifiable_diseases, [ Types::NotifiableDiseaseVersionType ], null: false,
            description: "Versões da lista nacional de notificação compulsória (da mais nova)"
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
      # ADR 0034 (contrato §8): plataforma, sem abrir cidade, sem segredo.
      field :sncr_status, Types::SncrStatusType, null: false,
            description: "SNCR do ambiente: configurado, alcançável e simulado disponível"
      # ADR 0033 (contrato §8): catálogo de medicamentos da plataforma.
      field :medication_catalog, Types::MedicationCatalogType, null: false,
            description: "Release ativa do CATMAT e itens em revisão"
      # ADR 0035 (contrato §6): configuração do PEC da cidade (o tipo abre o
      # banco dela); só sessão humana (HumanOnly).
      field :city_pec_config, Types::CityPecConfigType, null: true,
            description: "Configuração do PEC da cidade, sem a chave" do
        argument :city_slug, String, required: true
      end

      ProviderRow = Data.define(:key, :configured, :last_check_at, :last_check_ok)

      def lab_exam_templates = LabExamTemplate.includes(:analytes).order(:name)

      def care_line_templates(key: nil)
        scope = CareLineTemplate.all
        scope = scope.where(key: key) if key
        rows = scope.to_a
        context[:care_line_current_versions] = rows.group_by(&:key).transform_values { |list| list.map(&:version).max }
        context[:care_line_template_authors] = Maintainer.where(id: rows.filter_map(&:created_by_maintainer_id).uniq)
                                                         .pluck(:id, :email_address).to_h
        order = CareLines::Catalog::TEMPLATE_KEYS
        rows.sort_by { |t| [ order.index(t.key) || order.size, -t.version ] }
      end

      def notifiable_diseases
        rows = NotifiableDiseaseVersion.includes(:diseases).order(version: :desc).to_a
        context[:notifiable_current_version] = Surveillance::DiseaseList.current(today: Time.zone.today)&.version
        context[:notifiable_list_authors] = Maintainer.where(id: rows.filter_map(&:published_by_maintainer_id).uniq)
                                                      .pluck(:id, :email_address).to_h
        rows
      end

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

      def sncr_status = Sncr::Checks.status

      def medication_catalog = {}

      # Mesma forma de `city`: aqui só o escopo do token e a escolha da
      # cidade; quem abre o banco dela é CityPecConfigType (via CityReader).
      def city_pec_config(city_slug:)
        unless context.fetch(:credential).allows_city?(city_slug)
          raise GraphQL::ExecutionError.new("cidade fora do escopo do token",
                                            extensions: { "code" => Analyzers::Refusal::CITY_OUT_OF_SCOPE,
                                                          Analyzers::Refusal::FIELDS => [ "cityPecConfig" ] })
        end

        City.find_by(slug: city_slug)
      end

      # O escopo do token é aplicado AQUI (spec §7): é um dos pontos em que uma
      # cidade é escolhida (com `cities` e, no ADR 0035, `cityPecConfig`); a
      # conexão é aberta pelo tipo devolvido (CityType; CityPecConfigType só
      # para a configuração do PEC), nunca pelo resolver de raiz. Slug inexistente
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
