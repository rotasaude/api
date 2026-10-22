module Maintenance
  module Mutations
    # Contrato §8: grava a versão seguinte da linha no catálogo-base. Só
    # plataforma; sem step-up (como o catálogo do laboratório); auditado
    # pela base (attempted/ok|rejected) e por care_line.template_changed.
    class UpsertCareLineTemplate < BaseMutation
      description "Grava uma nova versão de uma linha do catálogo-base de linhas de cuidado."

      argument :key, String, required: true
      argument :name, String, required: true
      argument :indicator, String, required: true
      argument :declared_condition, String, required: false
      argument :eligibility, GraphQL::Types::JSON, required: true
      argument :practices, GraphQL::Types::JSON, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(**attrs)
        audited(event: "maintenance.care_line_template.changed", module_name: "care_lines", template_key: attrs[:key]) do
          result = CareLines::Templates::Save.call(attrs, maintainer: credential.maintainer)
          raise Rejected.new(result.reason.to_s, path: result.details[:field]) if result.failure?
        end
      end
    end
  end
end
