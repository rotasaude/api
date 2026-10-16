# Carga inicial do catálogo-base (spec §4): exames da APS com referência de
# PARTIDA ("ajuste ao seu método"). Idempotente: cria o que falta pelo
# sigtap_code e nunca sobrescreve (a curadoria é do maintenance). Faixa
# compacta no YAML: [sexo, baixo, alto] ou [sexo, baixo, alto, texto];
# idade 0..43800. Pula (e devolve) código fora da SIGTAP ativa.
module Lab
  module Templates
    module Load
      DEFAULT_PATH = Rails.root.join("config/lab/catalog-base.yml")

      module_function

      def entries(path = DEFAULT_PATH) = YAML.safe_load_file(path)
      def sigtap_codes(path = DEFAULT_PATH) = entries(path).map { |e| e.fetch("sigtap_code") }

      def call(path = DEFAULT_PATH)
        created = 0
        skipped = []
        entries(path).each do |entry|
          next if LabExamTemplate.exists?(sigtap_code: entry["sigtap_code"])

          PlatformRecord.transaction do
            exam = SaveExam.call(entry.slice(*%w[sigtap_code name sector material container suggested_method preparation]).merge("active" => true))
            next skipped << entry["sigtap_code"] if exam.failure? && exam.reason == :sigtap_unknown
            raise ArgumentError, "catálogo-base: #{entry['sigtap_code']} #{exam.reason}" if exam.failure?

            entry.fetch("analytes").each_with_index do |analyte, index|
              saved = SaveAnalyte.call(analyte.except("ranges").merge(
                "lab_exam_template_id" => exam.payload[:template].id, "position" => index + 1,
                "decimals" => analyte.fetch("decimals", 0), "choices" => analyte.fetch("choices", []),
                "reference_ranges" => Array(analyte["ranges"]).map { |sex, low, high, text| range(sex, low, high, text) }
              ))
              raise ArgumentError, "catálogo-base: #{entry['sigtap_code']}/#{analyte['key']} #{saved.reason}" if saved.failure?
            end
            created += 1
          end
        end
        { created: created, skipped: skipped }
      end

      def range(sex, low, high, text)
        { "sex" => sex, "age_min_days" => 0, "age_max_days" => Ranges::MAX_AGE_DAYS, "low" => low, "high" => high, "text" => text }
      end
      private_class_method :range
    end
  end
end
