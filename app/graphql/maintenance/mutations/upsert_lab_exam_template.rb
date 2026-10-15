module Maintenance
  module Mutations
    # Contrato §10 (M1, M3, M4, M7): cria (id nulo) ou altera um exame do
    # catálogo-base. Só plataforma; sem step-up; auditado pela base.
    class UpsertLabExamTemplate < BaseMutation
      description "Cria ou altera um exame do catálogo-base do laboratório."

      argument :id, ID, required: false
      argument :sigtap_code, String, required: true
      argument :name, String, required: true
      argument :sector, String, required: true
      argument :material, String, required: true
      argument :container, String, required: true
      argument :suggested_method, String, required: false
      argument :preparation, String, required: false
      argument :active, Boolean, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(**attrs)
        audited(event: "maintenance.lab_template.changed", module_name: "lab", sigtap_code: attrs[:sigtap_code]) do
          result = Lab::Templates::SaveExam.call(attrs)
          raise Rejected.new(result.reason.to_s, path: result.details[:path]) if result.failure?
        end
      end
    end
  end
end
