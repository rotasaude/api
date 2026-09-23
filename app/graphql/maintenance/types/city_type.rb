module Maintenance
  module Types
    class CityType < BaseObject
      description "Uma cidade. Só este tipo alcança o banco da cidade, e só por city(slug:)."

      field :slug, String, null: false
      field :name, String, null: false
      # P6: igual a CitySummary — `cities.uf` é opcional no catálogo real, e uma
      # cidade sem `uf` não pode derrubar a resposta inteira.
      field :uf, String, null: true
      # M1: mesmo CityStatus de CitySummary — ver o comentário lá.
      field :status, Types::CityStatusEnum, null: false
      # P7 (fix round 1): `ibgeCode` NÃO mora aqui — `cities` na plataforma não
      # tem essa coluna (achado do Task 2, ver task-2-report.md), e um campo
      # que sempre responde nulo é pior que nenhum campo. Quem quiser o código
      # IBGE lê `city.profile.ibgeCode` (Task 3), que é onde o dado de verdade
      # mora — dentro do banco da cidade, em `CityProfile`.
      field :schema_version, String, null: true
      field :schema_behind, Boolean, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false
      field :channel, Types::CityChannelType, null: true

      # Task 3: o lado de dentro do banco da cidade. Cada campo abre a conexão
      # por `CityReader` (uma entrada por campo — barato, o pool já está
      # registrado; ver "Atenção ao custo" no brief). `profile` e
      # `consentTermVersion` são `null: true` porque uma cidade real pode não
      # ter perfil/termo ainda (spec §8: uma linha ausente nunca derruba a
      # resposta inteira); `protocols`, `alertRecipients` e `accounts` são
      # listas — ausência vira lista vazia, não nulo.
      #
      # P9 (fix round 1): `consent_terms.version` é STRING no banco da cidade
      # (db/city_schema.rb), não Integer — um MAX de string seria
      # lexicográfico ("9" > "10") e o coercer Int do graphql-ruby
      # faz `to_i` silenciosamente ("v2" → 0). O campo é tipado `String` e
      # resolve pela MESMA definição de "versão vigente" que o resto do app
      # usa (`Consents.current_version`, app/services/consents.rb) — nunca
      # duplica a lógica de "qual é a atual" aqui.
      field :profile, Types::CityProfileType, null: true
      field :consent_term_version, String, null: true
      field :protocols, [ Types::ProtocolDefinitionType ], null: false
      # Plano 2 do frontend (telas de escrita): TODAS as versões, com o estado
      # de assinatura — `protocols` acima segue só com as ativas (contrato já
      # consumido). Teto de 100 como as listas de `operations`: cada versão
      # custa algumas consultas de assinatura.
      field :protocol_versions, [ Types::ProtocolVersionType ], null: false
      field :alert_recipients, [ Types::AlertRecipientType ], null: false
      field :accounts, [ Types::CityAccountType ], null: false

      # Task 4: sinais operacionais. `null: true` como `profile` — não é que a
      # contagem/os sinais estejam "legitimamente ausentes" numa cidade real,
      # é que os dois só existem depois de abrir a conexão (mesmo `inside` de
      # baixo), e um erro ali (CITY_ARCHIVED/CITY_UNREACHABLE) precisa nulificar
      # SÓ este campo, nunca a cidade inteira — senão uma cidade inalcançável
      # apagaria até `slug`/`status`, que responderam sem abrir banco nenhum.
      field :counts, Types::CityCountsType, null: true
      field :operations, Types::CityOperationsType, null: true

      def schema_behind = CitySchema.behind?(object)

      # Canal mora na PLATAFORMA, ao lado do catálogo: sai sem abrir conexão de
      # cidade (mesma escolha de CityInventory#channel_for).
      def channel
        CityChannel.where(city_id: object.id).order(active: :desc, created_at: :desc).first
      end

      def profile = inside { CityProfile.current }
      def consent_term_version = inside { Consents.current_version }
      def protocols = inside { ProtocolDefinition.active.order(:name).to_a }

      # Calculado DENTRO de `inside`: a conexão da cidade fecha ao sair do
      # bloco, então ProtocolVersionType só lê as chaves já prontas.
      #
      # A1 (fix wave): não-aposentadas primeiro, aposentadas por último —
      # nessa ordem, dentro de cada grupo, nome asc e versão desc. Sem o
      # CASE, uma aposentada de nome cedo no alfabeto (ex. "amarelo")
      # ocuparia uma vaga do teto de 100 antes de uma versão VIVA de nome
      # tardio (ex. "zika"), derrubando a viva da resposta — order(:name,
      # version: :desc).limit(100) sozinho não protege contra isso.
      def protocol_versions
        inside do
          ProtocolDefinition
            .order(Arel.sql("CASE WHEN status = 'retired' THEN 1 ELSE 0 END"), :name, version: :desc)
            .limit(100).map do |d|
            # Calculado uma vez e derivado nos dois campos abaixo — duas
            # consultas por versão custariam o dobro e poderiam divergir.
            target = Protocols::RevertActivation.revert_target(d)
            {
              name: d.name, version: d.version, status: d.status,
              publication_signatures: Protocols::Signatures.valid_signer_ids(d, purpose: "publication").size,
              publication_missing: Protocols::Signatures.missing(d, purpose: "publication"),
              activation_signatures: Protocols::Signatures.valid_signer_ids(d, purpose: "activation").size,
              activation_missing: Protocols::Signatures.missing(d, purpose: "activation"),
              eligible_reviewers: Protocols::Signatures.eligible_reviewer_count(d),
              revertible: target.present?,
              revert_target_version: target&.version
            }
          end
        end
      end

      def alert_recipients = inside { AlertRecipient.active.order(:escalation_order).to_a }

      # login É o e-mail de conta de STAFF da prefeitura, não de cidadão (mesma
      # informação que /maintenance já mostra). password_digest, otp_secret e
      # recovery codes ficam de fora por regra: o que serve para operar é saber
      # SE a conta exige MFA.
      def accounts
        inside do
          User.order(:email_address).map do |user|
            { login: user.email_address, roles: user.memberships.active.order(:role).pluck(:role),
              active: user.active?, mfa_enrolled: user.mfa_enrolled? }
          end
        end
      end

      # `count` puro (spec §8: sem carregar linha nenhuma) — a mesma conexão
      # de `inside` já sustenta as outras leituras de dentro do banco da
      # cidade, então um Hash simples basta: CityCountsType só lê as chaves.
      def counts
        inside do
          {
            users: User.count,
            conversations: Conversation.count,
            triages: Triage.count,
            inbound_messages: InboundMessage.count,
            report_snapshots: ReportSnapshot.count,
            consents: Consent.count
          }
        end
      end

      # Um só `inside` cobre as quatro listas: CityOperationsType e os tipos
      # que ela referencia (DomainEventType, ReportSnapshotType,
      # DashboardMetricType, FailedJobType) são "objetos simples" — só leem
      # dos registros já carregados aqui, sem abrir conexão de novo.
      #
      # Teto de 50 em TODAS as quatro listas: o brief só amarra domainEvents e
      # failedJobs a 50; reportSnapshots (1 por triage) e dashboardMetrics
      # (cresce por dia × dimensão × chave) crescem sem limite do mesmo jeito
      # — um teto consistente evita carregar uma tabela inteira por engano.
      def operations
        inside do
          {
            domain_events: DomainEvent.order(occurred_at: :desc).limit(50).to_a,
            report_snapshots: ReportSnapshot.order(created_at: :desc).limit(50).to_a,
            dashboard_metrics: DashboardMetric.order(updated_at: :desc).limit(50).to_a,
            failed_jobs: SolidQueue::FailedExecution.includes(:job).order(created_at: :desc).limit(50).to_a
          }
        end
      end

      private

      # Um só ponto converte as três falhas previstas em erro de CAMPO: a
      # operação segue, e o cliente vê exatamente qual cidade não respondeu
      # (e, para uma falha que não é de conexão, só o nome da classe —
      # CityReader::Failed nunca carrega a mensagem original).
      def inside(&block)
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
