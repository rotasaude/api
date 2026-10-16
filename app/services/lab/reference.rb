# Referência e marca do valor (spec §5.6; Review Focus 3; B27): a faixa do
# sexo (senão `any`) que cobre a idade em dias na data da coleta (limites
# inclusivos); sem nascimento, só faixa de 0..43800. Crítico INCLUSIVO: valor
# igual a critical_low/critical_high é crítico e vence a faixa; igual a
# low/high da faixa é normal.
module Lab
  module Reference
    module_function

    def age_days(patient, on:)
      return nil if patient.birth_date.blank?

      (on - Date.iso8601(patient.birth_date)).to_i
    rescue Date::Error
      nil
    end

    def range_for(analyte, sex:, age_days:)
      ranges = Array(analyte["reference_ranges"])
      fits = lambda do |r|
        age_days.nil? ? (r["age_min_days"].to_i.zero? && r["age_max_days"].to_i >= Ranges::MAX_AGE_DAYS) : age_days.between?(r["age_min_days"], r["age_max_days"])
      end
      ranges.find { |r| r["sex"] == sex && fits.call(r) } || ranges.find { |r| r["sex"] == "any" && fits.call(r) }
    end

    def flag(analyte, number, sex:, age_days:)
      return "normal" unless analyte["value_type"] == "numeric" && number

      return "critical_low" if analyte["critical_low"] && number <= BigDecimal(analyte["critical_low"].to_s)
      return "critical_high" if analyte["critical_high"] && number >= BigDecimal(analyte["critical_high"].to_s)

      range = range_for(analyte, sex: sex, age_days: age_days)
      return "normal" unless range
      return "low" if range["low"] && number < BigDecimal(range["low"].to_s)
      return "high" if range["high"] && number > BigDecimal(range["high"].to_s)

      "normal"
    end

    # "12,0 a 15,5 g/dL", "até 190 mg/dL", "a partir de 40 mg/dL" ou o texto da faixa.
    def text(analyte, range)
      return nil unless range
      return range["text"] if range["text"].present?

      unit = analyte["unit"].present? ? " #{analyte['unit']}" : ""
      bounds = [ range["low"], range["high"] ]
      # Casas do componente; sem elas, as da faixa (12,0 a 15,5).
      decimals = analyte["decimals"] || bounds.compact.map { |n| (n % 1).zero? ? 0 : n.to_s.split(".").last.size }.max.to_i
      low, high = bounds.map { |n| n && Values.fixed(BigDecimal(n.to_s), decimals).tr(".", ",") }
      if low && high then "#{low} a #{high}#{unit}"
      elsif high then "até #{high}#{unit}"
      elsif low then "a partir de #{low}#{unit}"
      end
    end
  end
end
