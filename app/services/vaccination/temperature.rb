# Temperatura em °C com no máximo uma casa decimal (numeric(4,1); §15 V14):
# número JSON ou texto com ponto ("8.5", "-1"). -> BigDecimal | nil.
module Vaccination
  module Temperature
    PATTERN = /\A-?\d{1,3}(\.\d)?\z/
    LIMIT = BigDecimal("999.9")

    module_function

    def parse(raw)
      text = case raw
      when Integer then raw.to_s
      when Float then raw.finite? ? raw.to_s.sub(/\.0\z/, "") : nil
      when String then raw.strip
      end
      return nil unless text&.match?(PATTERN)

      value = BigDecimal(text)
      value.abs <= LIMIT ? value : nil
    end

    # Para o JSON: número com uma casa.
    def dump(value) = value.to_d.round(1).to_f
  end
end
