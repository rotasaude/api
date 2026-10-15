# upsertLabExamTemplate (Divergências M1, M3, M4, M7): id nulo cria. Erros
# com o campo em camelCase. Só na plataforma; auditoria lab.template_changed
# (só ids — R18).
module Lab
  module Templates
    module SaveExam
      REQUIRED = { name: "name", material: "material", container: "container" }.freeze

      module_function

      def call(attrs)
        attrs = attrs.to_h.symbolize_keys
        template = attrs[:id] ? LabExamTemplate.find_by(id: attrs[:id]) : LabExamTemplate.new
        return fail(:not_found, "id") unless template

        REQUIRED.each { |field, path| return fail(:blank, path) if attrs[field].to_s.strip.empty? }
        return fail(:invalid_sector, "sector") unless LabExamTemplate::SECTORS.include?(attrs[:sector])

        code = attrs[:sigtap_code].to_s
        return fail(:sigtap_unknown, "sigtapCode") unless ClinicalTerms::SigtapExams.find(code, on: Time.zone.today)
        return fail(:duplicate_sigtap, "sigtapCode") if LabExamTemplate.where(sigtap_code: code).where.not(id: template.id).exists?

        created = template.new_record?
        template.update!(sigtap_code: code, name: attrs[:name].strip[0, 120], sector: attrs[:sector],
                         material: attrs[:material].strip[0, 60], container: attrs[:container].strip[0, 60],
                         suggested_method: attrs[:suggested_method].to_s.strip.presence&.slice(0, 160),
                         preparation: attrs[:preparation].to_s.strip.presence, active: attrs[:active] != false)
        Platform.audit("lab.template_changed", lab_exam_template_id: template.id,
                                               change: created ? "exam_created" : "exam_updated")
        Result.ok(template: template)
      rescue ActiveRecord::RecordNotUnique
        fail(:duplicate_sigtap, "sigtapCode")
      end

      def fail(code, path) = Result.fail(code, details: { path: path })
      private_class_method :fail
    end
  end
end
