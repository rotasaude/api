# Sinais vitais da escuta (ADR 0030; spec §3.1). Puro e total: aceita o que a
# tela manda (número, texto com vírgula ou ponto, vazio = não medido), recusa
# o implausível dizendo o campo, destaca o que está em faixa de alerta e
# calcula o IMC. Os mesmos limites estão nas CHECKs de screening_revisions.
module Screenings
  module VitalSigns
    FIELDS = ScreeningRevision::VITAL_COLUMNS
    INTEGER_FIELDS = %w[systolic diastolic heart_rate respiratory_rate spo2 capillary_glucose height_cm pain_score].freeze
    DECIMAL_SCALE = { "temperature_c" => 1, "weight_kg" => 2 }.freeze
    PLAUSIBLE = {
      "systolic" => 50..300, "diastolic" => 20..200, "heart_rate" => 20..250, "respiratory_rate" => 4..80,
      "temperature_c" => 30..45, "spo2" => 50..100, "capillary_glucose" => 10..800,
      "weight_kg" => BigDecimal("0.5")..400, "height_cm" => 30..250, "pain_score" => 0..10
    }.freeze
    GLUCOSE_MOMENTS = %w[fasting postprandial random].freeze
    NUMBER = /\A\d+(?:[.,]\d+)?\z/
    ALERT_RULES = [
      [ "systolic_high", "systolic", ->(v) { v >= 140 } ],
      [ "diastolic_high", "diastolic", ->(v) { v >= 90 } ],
      [ "heart_rate_high", "heart_rate", ->(v) { v > 100 } ],
      [ "heart_rate_low", "heart_rate", ->(v) { v < 50 } ],
      [ "respiratory_rate_high", "respiratory_rate", ->(v) { v > 24 } ],
      [ "temperature_high", "temperature_c", ->(v) { v >= BigDecimal("37.8") } ],
      [ "spo2_low", "spo2", ->(v) { v < 95 } ],
      [ "glucose_low", "capillary_glucose", ->(v) { v < 70 } ],
      [ "glucose_high", "capillary_glucose", ->(v) { v >= 200 } ],
      [ "pain_severe", "pain_score", ->(v) { v >= 7 } ]
    ].freeze

    module_function

    def parse(raw)
      raw = {} if raw.nil?
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      return implausible("vitals") unless raw.is_a?(Hash)

      raw = raw.transform_keys(&:to_s)
      values = {}
      FIELDS.each do |field|
        value = raw[field]
        next if value.nil? || (value.is_a?(String) && value.strip.empty?)

        parsed = field == "glucose_moment" ? moment(value) : measure(field, value)
        return implausible(field) if parsed.nil?

        values[field] = parsed
      end
      return Result.fail(:bp_incomplete) if values.key?("systolic") != values.key?("diastolic")
      return implausible("diastolic") if values.key?("systolic") && values["diastolic"] >= values["systolic"]
      return implausible("glucose_moment") if values.key?("capillary_glucose") && !values.key?("glucose_moment")
      return implausible("capillary_glucose") if values.key?("glucose_moment") && !values.key?("capillary_glucose")

      Result.ok(values: values, alerts: alerts(values), bmi: bmi(values))
    end

    def alerts(values)
      ALERT_RULES.filter_map { |name, field, rule| name if values[field] && rule.call(values[field]) }
    end

    def bmi(values)
      weight = values["weight_kg"]
      height = values["height_cm"]
      return nil unless weight && height

      (weight.to_f / ((height.to_f / 100)**2)).round(1)
    end

    def json(values) = values.transform_values { |v| v.is_a?(BigDecimal) ? v.to_f : v }

    def implausible(field) = Result.fail(:implausible_vital, details: { field: field })

    def moment(value) = GLUCOSE_MOMENTS.include?(value.to_s) ? value.to_s : nil

    def measure(field, value)
      number = to_decimal(value)
      return nil if number.nil?

      number = if INTEGER_FIELDS.include?(field)
                 number.frac.zero? ? number.to_i : nil
               else
                 number.round(DECIMAL_SCALE.fetch(field), BigDecimal::ROUND_HALF_UP)
               end
      number && PLAUSIBLE.fetch(field).cover?(number) ? number : nil
    end

    def to_decimal(value)
      case value
      when Integer then BigDecimal(value)
      when Float, BigDecimal then BigDecimal(value.to_s)
      when String then value.strip.match?(NUMBER) ? BigDecimal(value.strip.tr(",", ".")) : nil
      end
    end
    private_class_method :implausible, :moment, :measure, :to_decimal
  end
end
