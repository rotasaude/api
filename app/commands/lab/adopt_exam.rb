# Adotar um exame do catálogo-base (contrato §3): copia nome, material,
# recipiente, método sugerido e componentes para a versão 1 (sem limites,
# crítico ou fórmula — o laboratório ajusta numa versão nova).
module Lab
  module AdoptExam
    DEFAULT_METHOD = "Conforme o fabricante do reagente".freeze

    module_function

    def call(provider:, template_id:, sector:, bench:, delivery_days:, by:)
      template = template_id.is_a?(String) && LabExamTemplate.includes(:analytes).find_by(id: template_id, active: true)
      return Result.fail(:invalid_template) unless template
      return Result.fail(:invalid_sector) unless LabExam::SECTORS.include?(sector)
      return Result.fail(:invalid_delivery_days) unless delivery_days.is_a?(Integer) && delivery_days.between?(1, 90)
      return Result.fail(:invalid_bench) unless bench.nil? || (bench.is_a?(String) && bench.strip.length <= 60)

      analytes = template.analytes.map do |a|
        { "key" => a.key, "name" => a.name, "loinc" => a.loinc, "unit" => a.unit, "value_type" => a.value_type, "choices" => a.choices,
          "decimals" => a.decimals, "reference_ranges" => a.reference_ranges, "entry_min" => nil, "entry_max" => nil,
          "critical_low" => nil, "critical_high" => nil, "formula" => nil }
      end
      return Result.fail(:invalid_template) if analytes.empty?

      ApplicationRecord.transaction do
        exam = LabExam.create!(exam_provider: provider, lab_exam_template_id: template.id, sigtap_code: template.sigtap_code,
                               name: template.name, sector: sector, bench: bench&.strip.presence, delivery_days: delivery_days)
        version = LabExamVersion.create!(lab_exam: exam, version: 1, analysis_method: template.suggested_method.presence || DEFAULT_METHOD,
                                         material: template.material, container: template.container, analytes: analytes,
                                         created_by_user: by)
        exam.update!(current_version: version)
        DomainEvents.publish("lab_exam.version_created", lab_exam_id: exam.id, version: 1)
        Result.ok(exam: exam)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_sigtap)
    end
  end
end
