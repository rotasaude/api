module Maintenance
  module Types
    class CityCountsType < BaseObject
      description "Contagens do banco da cidade — nenhum dado de cidadão sai daqui, só números (spec §8)."

      field :users, Integer, null: false
      field :conversations, Integer, null: false
      field :triages, Integer, null: false
      field :inbound_messages, Integer, null: false
      field :report_snapshots, Integer, null: false
      field :consents, Integer, null: false
    end
  end
end
