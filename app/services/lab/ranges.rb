# Faixas de referência (spec §4; Divergência M5): lista de
# { sex: male|female|any, age_min_days, age_max_days (0..43800, obrigatórios),
#   low, high (nulos = sem limite daquele lado), text }. Vírgula decimal aceita.
module Lab
  module Ranges
    SEXES = %w[male female any].freeze
    MAX_AGE_DAYS = 43_800
    MAX = 20

    module_function

    def parse(raw)
      return fail_ranges unless raw.is_a?(Array) && raw.size <= MAX

      ranges = raw.map do |entry|
        entry = entry.respond_to?(:to_h) ? entry.to_h.transform_keys(&:to_s) : {}
        min, max = entry["age_min_days"], entry["age_max_days"]
        return fail_ranges unless SEXES.include?(entry["sex"]) && age?(min) && age?(max) && min <= max

        low, high = number(entry["low"]), number(entry["high"])
        return fail_ranges if low == :invalid || high == :invalid || (low && high && low > high)

        text = entry["text"].nil? ? nil : entry["text"].to_s.strip.presence
        return fail_ranges if text && text.length > 120

        { "sex" => entry["sex"], "age_min_days" => min, "age_max_days" => max, "low" => low, "high" => high, "text" => text }
      end
      Result.ok(ranges: ranges)
    end

    # nil, número, ou :invalid. "12,5" vale 12.5.
    def number(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)
      return value.to_f if value.is_a?(Numeric)
      return :invalid unless value.is_a?(String) && value.strip.match?(/\A-?\d+([.,]\d+)?\z/)

      value.strip.tr(",", ".").to_f
    end

    def age?(value) = value.is_a?(Integer) && value.between?(0, MAX_AGE_DAYS)
    def fail_ranges = Result.fail(:invalid_reference_ranges)
    private_class_method :age?, :fail_ranges
  end
end
