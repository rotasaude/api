# upsertLabAnalyteTemplate (Divergências M1, M3, M5): id nulo cria no exame.
module Lab
  module Templates
    module SaveAnalyte
      module_function

      def call(attrs)
        attrs = attrs.to_h.symbolize_keys
        template = LabExamTemplate.find_by(id: attrs[:lab_exam_template_id])
        return fail(:not_found, "labExamTemplateId") unless template

        analyte = attrs[:id] ? template.analytes.find_by(id: attrs[:id]) : template.analytes.new
        return fail(:not_found, "id") unless analyte

        key = attrs[:key].to_s
        return fail(:invalid_analyte_key, "key") unless key.match?(LabAnalyteTemplate::KEY)
        return fail(:duplicate_analyte_key, "key") if template.analytes.where(key: key).where.not(id: analyte.id).exists?
        return fail(:blank, "name") if attrs[:name].to_s.strip.empty?
        return fail(:invalid_value_type, "valueType") unless LabAnalyteTemplate::VALUE_TYPES.include?(attrs[:value_type])

        choices = Array(attrs[:choices]).map { |c| c.to_s.strip }
        if attrs[:value_type] == "choice" && !valid_choices?(choices)
          return fail(:choices_required, "choices")
        end

        loinc = attrs[:loinc].to_s.strip.presence
        return fail(:invalid_loinc, "loinc") if loinc && !loinc.match?(LabAnalyteTemplate::LOINC)
        return fail(:invalid_decimals, "decimals") unless attrs[:decimals].is_a?(Integer) && attrs[:decimals].between?(0, 4)

        ranges = Ranges.parse(Array(attrs[:reference_ranges]))
        return fail(:invalid_reference_ranges, "referenceRanges") if ranges.failure?

        created = analyte.new_record?
        analyte.update!(key: key, name: attrs[:name].strip[0, 120], loinc: loinc, unit: attrs[:unit].to_s.strip.presence&.slice(0, 30),
                        value_type: attrs[:value_type], choices: attrs[:value_type] == "choice" ? choices : [],
                        decimals: attrs[:decimals], reference_ranges: ranges.payload[:ranges], position: attrs[:position].to_i)
        Platform.audit("lab.template_changed", lab_exam_template_id: template.id,
                                               change: created ? "analyte_created" : "analyte_updated")
        Result.ok(analyte: analyte)
      rescue ActiveRecord::RecordNotUnique
        fail(:duplicate_analyte_key, "key")
      end

      MAX_CHOICES = 20
      MAX_CHOICE_LENGTH = 60

      # Lista de opções: 1 a 20, cada uma de 1 a 60 caracteres, sem repetição.
      def valid_choices?(choices)
        choices.size.between?(1, MAX_CHOICES) && choices.uniq.size == choices.size &&
          choices.all? { |c| c.length.between?(1, MAX_CHOICE_LENGTH) }
      end

      def fail(code, path) = Result.fail(code, details: { path: path })
      private_class_method :fail, :valid_choices?
    end
  end
end
