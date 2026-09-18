module Maintenance
  module Types
    class CityType < BaseObject
      description "Uma cidade. Só este tipo alcança o banco da cidade, e só por city(slug:)."

      field :slug, String, null: false
      field :name, String, null: false
      # P6: igual a CitySummary — `cities.uf` é opcional no catálogo real, e uma
      # cidade sem `uf` não pode derrubar a resposta inteira.
      field :uf, String, null: true
      field :status, String, null: false
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
      # (db/city_schema.rb), não Integer — `ConsentTerm.maximum(:version)`
      # sozinho é lexicográfico ("9" > "10") e o coercer Int do graphql-ruby
      # faz `to_i` silenciosamente ("v2" → 0). O campo é tipado `String` e
      # resolve pela MESMA definição de "versão vigente" que o resto do app
      # usa (`Consents.current_version`, app/services/consents.rb) — nunca
      # duplica a lógica de "qual é a atual" aqui.
      field :profile, Types::CityProfileType, null: true
      field :consent_term_version, String, null: true
      field :protocols, [ Types::ProtocolDefinitionType ], null: false
      field :alert_recipients, [ Types::AlertRecipientType ], null: false
      field :accounts, [ Types::CityAccountType ], null: false

      def schema_behind = CitySchema.behind?(object)

      # Canal mora na PLATAFORMA, ao lado do catálogo: sai sem abrir conexão de
      # cidade (mesma escolha de CityInventory#channel_for).
      def channel
        CityChannel.where(city_id: object.id).order(active: :desc, created_at: :desc).first
      end

      def profile = inside { CityProfile.current }
      def consent_term_version = inside { Consents.current_version }
      def protocols = inside { ProtocolDefinition.active.order(:name).to_a }
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

      private

      # Um só ponto converte as duas falhas previstas em erro de CAMPO: a
      # operação segue, e o cliente vê exatamente qual cidade não respondeu.
      def inside(&block)
        CityReader.call(object, &block)
      rescue CityReader::Archived => e
        raise GraphQL::ExecutionError.new(e.message, extensions: { "code" => "CITY_ARCHIVED" })
      rescue CityReader::Unreachable => e
        raise GraphQL::ExecutionError.new(e.message, extensions: { "code" => "CITY_UNREACHABLE" })
      end
    end
  end
end
