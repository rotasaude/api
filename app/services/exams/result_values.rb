# Valores do resultado (spec §4): pela chave do campo do catálogo (unidade,
# prestador) ou pelo LOINC (FHIR; LOINC desconhecido fica sem chave). Nunca
# devolve o valor recusado (nem em details): só o motivo.
module Exams
  module ResultValues
    MAX = 60

    module_function

    def from_input(item, raw)
      raw = Array(raw).map { |v| v.respond_to?(:to_unsafe_h) ? v.to_unsafe_h : v }
      return Result.fail(:invalid_values) unless raw.size <= MAX && raw.all?(Hash)

      values = raw.map do |entry|
        entry = entry.stringify_keys
        field = item&.result_field(entry["key"].to_s)
        value = entry["value"]
        return Result.fail(:invalid_values) unless field && (value.is_a?(String) || value.is_a?(Numeric)) && value.to_s.strip.length.between?(1, 200)

        { "key" => field["key"], "label" => field["label"], "value" => value.to_s.strip, "unit" => field["unit"], "loinc" => field["loinc"] }
      end
      return Result.fail(:invalid_values) unless values.map { |v| v["key"] }.uniq.size == values.size

      Result.ok(values: values)
    end

    def from_fhir(item, observations)
      observations.first(MAX).map do |obs|
        coding = Array(obs.dig("code", "coding")).find { |c| c["system"] == "http://loinc.org" } || Array(obs.dig("code", "coding")).first || {}
        field = item&.result_field_by_loinc(coding["code"])
        value = obs["valueQuantity"] ? obs.dig("valueQuantity", "value").to_s : obs["valueString"].to_s
        { "key" => field&.fetch("key"), "label" => field&.fetch("label") || coding["display"].presence || coding["code"].to_s,
          "value" => value.strip[0, 200], "unit" => obs.dig("valueQuantity", "unit") || field&.fetch("unit"),
          "loinc" => coding["system"] == "http://loinc.org" ? coding["code"] : nil }
      end
    end
  end
end
