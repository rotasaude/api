# Apresentação do OBM sem item no catálogo (lista de revisão da carga, Q12).
# Sem dado de pessoa: o CNPJ é do fabricante.
module Maintenance
  module Types
    class ObmPresentationType < BaseObject
      description "Apresentação (AMPP) do OBM"

      field :ampp_code, String, null: false
      field :vmp_code, String, null: false
      field :catmat_code, Integer, null: true
      field :anvisa_registration, String, null: true
      field :manufacturer_cnpj, String, null: true
      field :description, String, null: false
      field :active, Boolean, null: false
      field :imported_at, GraphQL::Types::ISO8601DateTime, null: false
    end
  end
end
