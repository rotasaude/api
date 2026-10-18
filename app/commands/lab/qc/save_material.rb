# Material de controle (contrato §3): níveis (1..6, distintos) e analitos
# numéricos não calculados da versão vigente de exames do laboratório.
# Depois do primeiro lote, os níveis não mudam e nenhum analito sai.
module Lab
  module Qc
    module SaveMaterial
      module_function

      def call(params, provider: nil, material: nil)
        params = params.to_h.stringify_keys
        provider ||= material.exam_provider
        name = params["name"].is_a?(String) ? params["name"].strip : ""
        manufacturer = params["manufacturer"]
        return Result.fail(:invalid_name) unless name.length.between?(1, 80)
        return Result.fail(:invalid_name) unless manufacturer.nil? || (manufacturer.is_a?(String) && manufacturer.strip.length <= 80)

        levels = parse_levels(params["levels"])
        return Result.fail(:invalid_levels) unless levels

        analytes = parse_analytes(params["analytes"], provider)
        return Result.fail(:invalid_analytes) unless analytes
        # C-E12: a mesma chave de analito em dois exames deixaria referência e valor ambíguos.
        return Result.fail(:duplicate_analyte_key) unless analytes.map { |a| a["analyte_key"] }.uniq.size == analytes.size
        return Result.fail(:invalid_active) unless [ true, false ].include?(params["active"])

        ApplicationRecord.transaction(requires_new: true) do
          if material
            material.lock!
            if material.lots.exists?
              next Result.fail(:invalid_levels) unless levels == material.levels
              next Result.fail(:invalid_analytes) unless (material.analytes - analytes).empty?
            end
          end
          record = material || LabQcMaterial.new(exam_provider: provider)
          record.update!(name: name, manufacturer: manufacturer&.strip.presence, levels: levels, analytes: analytes, active: params["active"])
          Result.ok(material: record)
        end
      end

      def parse_levels(raw)
        return nil unless raw.is_a?(Array) && raw.size.between?(1, 6) && raw.all? { |l| l.is_a?(String) && l.strip.length.between?(1, 40) }

        levels = raw.map(&:strip)
        levels.uniq.size == levels.size ? levels : nil
      end

      def parse_analytes(raw, provider)
        return nil unless raw.is_a?(Array) && raw.size.between?(1, 60)

        exams = LabExam.where(exam_provider_id: provider.id).includes(:current_version).index_by(&:id)
        list = raw.map do |entry|
          entry = entry.to_unsafe_h if entry.respond_to?(:to_unsafe_h)
          return nil unless entry.is_a?(Hash)

          entry = entry.stringify_keys
          analyte = exams[entry["lab_exam_id"]]&.current_version&.analyte(entry["analyte_key"])
          return nil unless analyte && analyte["value_type"] == "numeric" && analyte["formula"].blank?

          { "lab_exam_id" => entry["lab_exam_id"], "analyte_key" => analyte["key"] }
        end
        list.uniq.size == list.size ? list : nil
      end
      private_class_method :parse_levels, :parse_analytes
    end
  end
end
