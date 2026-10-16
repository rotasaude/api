# JSON canônico do laudo (contrato §8; tag lab-v1.0.0, cópia em
# config/lab/lab-report-v1.json presa por SHA-256): o que o CAdES do 19b
# assina e de onde o PDF sai. Congelado na liberação (lab_reports.content).
# RFC 8785 (Signatures::Jcs). Sem CPF. Erro só com ponteiros, nunca valores.
#
# Só entram as linhas que valem (Lab::Effective; B30): `chosen` é história.
# Valor com as casas do componente (Values.fixed, BigDecimal); marca vinda da
# linha (Reference, crítico inclusivo B27). Calculado sem linha fica ausente
# (o item admitiu entrada parcial); componente digitável sem linha é recusa.
require "json_schemer"

module Lab
  module ReportContent
    SCHEMA = "rotasaude.lab_report.v1".freeze
    SCHEMA_PATH = Rails.root.join("config/lab/lab-report-v1.json")
    SCHEMA_SHA256 = "81ff762db67509b10ebcddc285874ab19a15b449964be46bfbf28d8c4fac7fb5".freeze

    class Invalid < StandardError; end
    Built = Data.define(:document, :json, :sha256) do
      def inspect = "#<Lab::ReportContent::Built #{sha256}>"
      alias_method :to_s, :inspect
    end

    module_function

    def laboratory_ready?(provider)
      provider.cnes.present? && provider.address.present? && provider.phone.present?
    end

    def build(requisition:, items:, released_by:, lead:, partial:, signature_kind:, issued_at:, replaces: nil, reason: nil)
      provider = requisition.exam_provider
      patient = requisition.patient
      document = {
        "schema" => SCHEMA,
        "laboratory" => { "name" => provider.name, "cnes" => provider.cnes, "address" => provider.address, "phone" => provider.phone },
        "technical_lead" => professional(lead), "released_by" => professional(released_by),
        "patient" => { "name" => patient.display_name, "birth_date" => patient.birth_date.presence,
                       "biological_sex" => requisition.biological_sex, "record_number" => requisition.number },
        "requisition_number" => requisition.number,
        "exams" => items.sort_by { |i| [ i.lab_exam_version.lab_exam.name, i.id ] }.map { |item| exam(item) },
        "partial" => partial, "issued_at" => issued_at.utc.iso8601, "signature_kind" => signature_kind,
        "replaces_report_id" => replaces&.id, "rectification_reason" => reason, "support_laboratory" => nil
      }
      validate!(document)
      json = Signatures::Jcs.dump(document)
      Built.new(document: document, json: json, sha256: Digest::SHA256.hexdigest(json))
    end

    def validate!(document)
      errors = schema.validate(document).first(5)
      return if errors.empty?

      raise Invalid, "laudo fora do esquema: #{errors.map { |e| pointer(e) }.join('; ')}"
    end

    # Ponteiro, tipo da regra e, em `required`, os NOMES das chaves que faltam
    # (do esquema, nunca valores do laudo).
    def pointer(error)
      missing = Array(error.dig("details", "missing_keys")).join(",")
      "#{error['data_pointer'].presence || '(root)'} #{error['type']}#{" [#{missing}]" if missing.present?}"
    end

    def professional(user)
      p = user.professional
      { "name" => p.professional_name, "council" => p.council, "council_uf" => p.council_state, "council_number" => p.registration_number }
    end

    def exam(item)
      version = item.lab_exam_version
      sample = item.lab_sample
      ctx = EnterResults.context(item)
      effective = Effective.rows(item)
      { "sigtap_code" => version.lab_exam.sigtap_code, "name" => version.lab_exam.name, "material" => version.material,
        "method" => version.analysis_method, "version" => version.version,
        "collected_at" => (sample.collected_at || sample.received_at).utc.iso8601, "restriction_note" => sample.restriction_note,
        "components" => version.analytes.filter_map { |analyte| component(analyte, effective[analyte["key"]], ctx) } }
    end

    def component(analyte, row, ctx)
      if row.nil?
        return nil if analyte["formula"].present?

        raise Invalid, "laudo fora do esquema: componente sem valor (#{analyte['key']})"
      end

      { "key" => analyte["key"], "name" => analyte["name"], "value" => display_value(analyte, row.value), "unit" => analyte["unit"],
        "flag" => row.flag.presence || "normal", "reference_text" => Reference.text(analyte, Reference.range_for(analyte, **ctx)),
        "loinc" => analyte["loinc"] }
    end

    # Numérico com as casas do componente (nunca Float); o resto como digitado.
    def display_value(analyte, value)
      return value unless analyte["value_type"] == "numeric" && value.to_s.match?(Values::NUMBER)

      Values.fixed(BigDecimal(value.tr(",", ".")), analyte["decimals"].to_i)
    end

    def schema = (@schema ||= JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH))))
    private_class_method :pointer, :professional, :exam, :component, :display_value, :schema
  end
end
