module Maintenance
  module Types
    class LabExamTemplateType < BaseObject
      graphql_name "LabExamTemplate"
      description "Exame do catálogo-base (plataforma). A cidade adota e versiona; mudar aqui só vale na próxima adoção."

      field :id, ID, null: false
      field :sigtap_code, String, null: false
      field :name, String, null: false
      field :sector, String, null: false
      field :material, String, null: false
      field :container, String, null: false
      field :suggested_method, String, null: true
      field :preparation, String, null: true
      field :active, Boolean, null: false
      field :analytes, [ Types::LabAnalyteTemplateType ], null: false, description: "Em ordem de position"
    end
  end
end
