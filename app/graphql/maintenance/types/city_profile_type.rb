module Maintenance
  module Types
    class CityProfileType < BaseObject
      description "Identidade da cidade no banco dela."

      field :name, String, null: false
      field :uf, String, null: true
      field :ibge_code, String, null: true
    end
  end
end
