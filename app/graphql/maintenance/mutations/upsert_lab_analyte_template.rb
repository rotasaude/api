module Maintenance
  module Mutations
    class UpsertLabAnalyteTemplate < BaseMutation
      description "Cria ou altera um componente de exame do catálogo-base."

      argument :id, ID, required: false
      argument :lab_exam_template_id, ID, required: true
      argument :key, String, required: true
      argument :name, String, required: true
      argument :loinc, String, required: false
      argument :unit, String, required: false
      argument :value_type, String, required: true
      argument :choices, [ String ], required: false, default_value: []
      argument :decimals, Int, required: true
      argument :position, Int, required: true
      argument :reference_ranges, [ Types::LabReferenceRangeInput ], required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      def resolve(**attrs)
        attrs[:reference_ranges] = attrs[:reference_ranges].map(&:to_h)
        audited(event: "maintenance.lab_template.changed", module_name: "lab", lab_exam_template_id: attrs[:lab_exam_template_id]) do
          result = Lab::Templates::SaveAnalyte.call(attrs)
          raise Rejected.new(result.reason.to_s, path: result.details[:path]) if result.failure?
        end
      end
    end
  end
end
