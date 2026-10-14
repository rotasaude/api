# Corpo do item do catálogo (contrato §5) → atributos. Só as chaves
# presentes mudam (PATCH). Nunca levanta.
module Exams
  module CatalogInput
    KEY = /\A[a-z][a-z0-9_]{0,39}\z/
    LOINC = /\A\d{1,7}-\d\z/

    module_function

    def call(params, item: nil, on: Time.zone.today)
      params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      params = params.deep_stringify_keys
      attrs = {}

      if params.key?("sigtap_code") || item.nil?
        exam = ClinicalTerms::SigtapExams.find(params["sigtap_code"], on: on)
        return Result.fail(:sigtap_unknown) unless exam
        return Result.fail(:duplicate_sigtap) if ExamCatalogItem.where(sigtap_code: exam.code).where.not(id: item&.id).exists?

        attrs[:sigtap_code] = exam.code
      end
      if params.key?("release_policy")
        return Result.fail(:invalid_policy) unless ExamCatalogItem::POLICIES.include?(params["release_policy"])

        attrs[:release_policy] = params["release_policy"]
      end
      %w[requires_authorization active].each do |flag|
        next unless params.key?(flag)
        return Result.fail(:"invalid_#{flag}") unless [ true, false ].include?(params[flag])

        attrs[flag.to_sym] = params[flag]
      end
      if params.key?("deadlines")
        days = deadlines(params["deadlines"])
        return Result.fail(:invalid_deadline) unless days

        attrs.merge!(days)
      end
      if params.key?("result_fields")
        fields = result_fields(params["result_fields"])
        return Result.fail(:invalid_result_fields) unless fields

        attrs[:result_fields] = fields
      end
      Result.ok(attrs: attrs)
    end

    # { stage => int 1..365 | nil } → { "<stage>_days" => ... }; chave desconhecida = nil.
    def deadlines(raw)
      return nil unless raw.is_a?(Hash)
      return nil unless (raw.keys - Deadlines::STAGES).empty?

      raw.each_with_object({}) do |(stage, value), acc|
        return nil unless value.nil? || (value.is_a?(Integer) && value.between?(1, 365))

        acc[:"#{stage}_days"] = value
      end
    end

    def result_fields(raw)
      return nil unless raw.is_a?(Array) && raw.size <= 40

      fields = raw.map do |field|
        return nil unless field.is_a?(Hash)

        field = field.deep_stringify_keys
        key, label, unit, loinc = field.values_at("key", "label", "unit", "loinc")
        return nil unless key.is_a?(String) && key.match?(KEY) && label.is_a?(String) && label.strip.length.between?(1, 80)
        return nil unless unit.nil? || (unit.is_a?(String) && unit.length <= 20)
        return nil unless loinc.nil? || (loinc.is_a?(String) && loinc.match?(LOINC))

        { "key" => key, "label" => label.strip, "unit" => unit.presence, "loinc" => loinc }
      end
      fields.map { |f| f["key"] }.uniq.size == fields.size ? fields : nil
    end
    private_class_method :deadlines, :result_fields
  end
end
