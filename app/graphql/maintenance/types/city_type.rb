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
      field :ibge_code, String, null: true
      field :schema_version, String, null: true
      field :schema_behind, Boolean, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false
      field :channel, Types::CityChannelType, null: true

      def schema_behind = CitySchema.behind?(object)

      # ACHADO (Task 2): `db/platform_schema.rb` não tem `ibge_code` na tabela
      # `cities` — só existe dentro do banco da cidade, em `CityProfile`
      # (db/city_schema.rb). O "fato verificado" do plano que listava
      # `ibge_code` como coluna de `City` está errado. Resolver aqui abrindo
      # `CityConnection.with` duplicaria a regra do campo `profile` (Tasks 3/4)
      # e quebraria para cidade arquivada/inalcançável, que este task ainda não
      # trata (sem CITY_ARCHIVED/CITY_UNREACHABLE aqui). Fica nulo — plataforma
      # não guarda o dado — até a Task 3/4 decidir se isso migra para `profile`
      # ou ganha coluna própria em `cities`.
      def ibge_code = nil

      # Canal mora na PLATAFORMA, ao lado do catálogo: sai sem abrir conexão de
      # cidade (mesma escolha de CityInventory#channel_for).
      def channel
        CityChannel.where(city_id: object.id).order(active: :desc, created_at: :desc).first
      end
    end
  end
end
