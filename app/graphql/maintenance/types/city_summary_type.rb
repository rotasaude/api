module Maintenance
  module Types
    class CityStatusEnum < GraphQL::Schema::Enum
      graphql_name "CityStatus"
      City::STATUSES.each { |status| value status.upcase, value: status }
    end

    class CitySummaryType < BaseObject
      description "Uma cidade do catálogo. Nada aqui vem do banco da cidade."

      field :slug, String, null: false
      field :name, String, null: false
      # P6: a coluna `cities.uf` é opcional (sem `null: false`, sem presence) —
      # uma cidade real sem `uf` não pode nulificar a lista inteira (spec §8:
      # a operação nunca cai por causa de uma cidade). `[CitySummary!]!` segue
      # não-nulo; só o CAMPO cede.
      field :uf, String, null: true
      # M1 (achado na revisão final do Plano 4): publica o CityStatus que o
      # filtro de `cities` já usa (spec §8: `status: CityStatus!`), em vez de
      # devolver a string crua da coluna — um cliente não tem como saber, só
      # pela String, quais são os valores possíveis.
      field :status, Types::CityStatusEnum, null: false
      field :schema_version, String, null: true
      field :schema_behind, Boolean, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false

      def schema_behind = CitySchema.behind?(object)
    end
  end
end
