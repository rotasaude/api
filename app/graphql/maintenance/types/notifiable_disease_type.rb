module Maintenance
  module Types
    class NotifiableDiseaseType < BaseObject
      graphql_name "NotifiableDisease"
      description "Doença ou agravo de uma versão da lista nacional de notificação compulsória. Imutável."

      field :code, String, null: false, description: "Código da doença na plataforma (minúsculas; nunca local_)"
      field :name, String, null: false
      field :deadline, String, null: false, description: "immediate (24 h) | weekly (7 dias)"
      field :cid10, [ String ], null: false
      field :ciap2, [ String ], null: false
      field :repeat_after_days, Integer, null: false
      field :sinan_form, String, null: true
      field :notes, String, null: true
      field :sources, GraphQL::Types::JSON, null: false, description: "Fonte de cada campo (ao menos deadline e cid10)"
    end
  end
end
