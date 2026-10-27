module Maintenance
  module Types
    class NotifiableDiseaseVersionType < BaseObject
      graphql_name "NotifiableDiseaseVersion"
      description "Versão da lista nacional de doenças e agravos de notificação compulsória. Imutável; vale para todas " \
                  "as cidades a partir de effectiveFrom."

      field :version, Integer, null: false
      field :ordinance, String, null: false, description: "Portaria de origem (ex.: Portaria GM/MS nº 11.211/2026)"
      field :effective_from, GraphQL::Types::ISO8601Date, null: false
      field :current, Boolean, null: false,
            description: "A versão em vigor hoje (maior versão com effectiveFrom até hoje, em America/Sao_Paulo)"
      field :notes, String, null: true
      field :sources, GraphQL::Types::JSON, null: true, description: "Proveniência da versão (portaria, pasta das fontes)"
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false
      field :published_by, String, null: true, description: "E-mail de quem publicou (nulo na carga inicial)"
      field :diseases, [ Types::NotifiableDiseaseType ], null: false

      def current = object.version == context[:notifiable_current_version]

      def published_by = context[:notifiable_list_authors]&.fetch(object.published_by_maintainer_id, nil)

      def diseases = object.diseases.sort_by(&:code)
    end
  end
end
