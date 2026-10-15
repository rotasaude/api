# Componentes de uma versão (contrato §3): chave, nome, LOINC, unidade, tipo,
# lista, casas, faixas (Lab::Ranges), limites de digitação, crítico e fórmula
# (só em numérico, sobre numéricos não calculados da MESMA versão).
module Lab
  module Analytes
    KEY = /\A[a-z][a-z0-9_]{0,39}\z/
    LOINC = /\A\d{1,7}-\d\z/
    TYPES = %w[numeric text choice].freeze
    MAX = 60
    LIMITS = %w[entry_min entry_max critical_low critical_high].freeze

    module_function

    def parse(raw)
      return invalid unless raw.is_a?(Array) && raw.size.between?(1, MAX)

      list = raw.map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry }
      return invalid unless list.all?(Hash)

      list = list.map(&:stringify_keys)
      return invalid unless list.map { |a| a["key"] }.uniq.size == list.size

      analytes = []
      list.each do |a|
        one = analyte(a)
        return one if one.is_a?(Result)

        analytes << one
      end
      numeric_keys = analytes.select { |a| a["value_type"] == "numeric" && a["formula"].nil? }.map { |a| a["key"] }
      analytes.each do |a|
        next unless a["formula"]
        return Result.fail(:invalid_formula) unless a["value_type"] == "numeric" && Formula.compile(a["formula"], allowed: numeric_keys)
      end
      Result.ok(analytes: analytes)
    end

    def analyte(a)
      return invalid unless a["key"].is_a?(String) && a["key"].match?(KEY)
      return invalid unless a["name"].is_a?(String) && a["name"].strip.length.between?(1, 120)
      return invalid unless TYPES.include?(a["value_type"])
      return invalid unless a["loinc"].nil? || (a["loinc"].is_a?(String) && a["loinc"].match?(LOINC))
      return invalid unless a["unit"].nil? || (a["unit"].is_a?(String) && a["unit"].length <= 30)
      return invalid unless a["decimals"].is_a?(Integer) && a["decimals"].between?(0, 4)

      # B29: mesma regra e mesmo código do catálogo-base (Lab::Choices); só em `choice`.
      choices = Choices.normalize(a["choices"])
      return Result.fail(:choices_required) if a["value_type"] == "choice" && !Choices.valid?(choices)

      ranges = Ranges.parse(Array(a["reference_ranges"]))
      return ranges if ranges.failure?

      limits = LIMITS.to_h { |k| [ k, Ranges.number(a[k]) ] }
      return invalid if limits.values.include?(:invalid)
      return invalid if a["value_type"] != "numeric" && limits.values.any?
      return invalid if limits["entry_min"] && limits["entry_max"] && limits["entry_min"] >= limits["entry_max"]

      return Result.fail(:invalid_formula) unless a["formula"].nil? || a["formula"].is_a?(String)

      formula = a["formula"]&.strip.presence
      return Result.fail(:invalid_formula) if formula && a["value_type"] != "numeric"

      { "key" => a["key"], "name" => a["name"].strip, "loinc" => a["loinc"], "unit" => a["unit"].presence,
        "value_type" => a["value_type"], "choices" => a["value_type"] == "choice" ? choices : [], "decimals" => a["decimals"],
        "reference_ranges" => ranges.payload[:ranges], **limits, "formula" => formula }
    end

    def invalid = Result.fail(:invalid_analytes)
    private_class_method :analyte, :invalid
  end
end
