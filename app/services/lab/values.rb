# Valor digitado ou recebido (spec §5.6): numérico com vírgula ou ponto,
# arredondado às casas do componente; bloqueio fora de entry_min/entry_max
# (inclusivos); lista só com as opções; texto até 200 caracteres. O valor
# recusado nunca volta em erro (só a chave do componente).
module Lab
  module Values
    NUMBER = /\A-?\d+([.,]\d+)?\z/
    MAX_DIGITS = 15 # algarismos significativos aceitos (mesmo sem entry_max)

    module_function

    def normalize(analyte, raw)
      key = analyte["key"]
      text = raw.is_a?(Numeric) ? raw.to_s : raw.to_s.strip
      case analyte["value_type"]
      when "numeric"
        return fail(:invalid_value, key) unless text.match?(NUMBER) && text.delete("-.,").sub(/\A0+/, "").size <= MAX_DIGITS

        raw_number = BigDecimal(text.tr(",", "."))
        min, max = analyte["entry_min"], analyte["entry_max"]
        # O limite vale para o valor como chegou (antes de arredondar às casas).
        return fail(:out_of_entry_range, key) if (min && raw_number < BigDecimal(min.to_s)) || (max && raw_number > BigDecimal(max.to_s))

        decimals = analyte["decimals"].to_i
        number = raw_number.round(decimals, BigDecimal::ROUND_HALF_UP)
        Result.ok(value: fixed(number, decimals), number: number)
      when "choice"
        Array(analyte["choices"]).include?(text) ? Result.ok(value: text, number: nil) : fail(:invalid_value, key)
      else
        text.length.between?(1, 200) ? Result.ok(value: text, number: nil) : fail(:invalid_value, key)
      end
    end

    # Casas fixas por BigDecimal (nunca Float): 2.5 com 2 casas = "2.50".
    def fixed(number, decimals)
      rounded = number.round(decimals, BigDecimal::ROUND_HALF_UP)
      return rounded.to_i.to_s if decimals.zero?

      whole, frac = rounded.to_s("F").split(".")
      "#{whole}.#{frac.to_s.ljust(decimals, '0')}"
    end

    def fail(code, key) = Result.fail(code, details: { analyte_key: key })
    private_class_method :fail
  end
end
