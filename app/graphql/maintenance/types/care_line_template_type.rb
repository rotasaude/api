module Maintenance
  module Types
    class CareLineTemplateType < BaseObject
      graphql_name "CareLineTemplate"
      description "Versão do catálogo-base de uma linha de cuidado (C2–C7). Imutável; a cidade adota uma versão."

      field :key, String, null: false
      field :version, Integer, null: false
      field :current, Boolean, null: false, description: "Maior versão da chave"
      field :name, String, null: false
      field :indicator, String, null: false
      field :declared_condition, String, null: true
      field :eligibility, GraphQL::Types::JSON, null: false
      field :practices, GraphQL::Types::JSON, null: false
      field :created_at, GraphQL::Types::ISO8601DateTime, null: false
      field :created_by, String, null: true, description: "E-mail de quem gravou a versão (nulo na carga inicial do YAML)"

      def current = object.version == context[:care_line_current_versions]&.fetch(object.key, nil)

      def created_by = context[:care_line_template_authors]&.fetch(object.created_by_maintainer_id, nil)
    end
  end
end
