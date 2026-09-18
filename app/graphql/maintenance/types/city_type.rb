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

      def schema_behind = CitySchema.behind?(object)

      # Canal mora na PLATAFORMA, ao lado do catálogo: sai sem abrir conexão de
      # cidade (mesma escolha de CityInventory#channel_for).
      def channel
        CityChannel.where(city_id: object.id).order(active: :desc, created_at: :desc).first
      end
    end
  end
end
