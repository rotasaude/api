# Números do CIQ, do CEQ e do estoque (Desvio 11): digitação com vírgula
# (ponto recusado — "1.234" é ambíguo); HL7 com ponto (NM); saída com ponto
# e sem zeros à direita. Sempre BigDecimal, nunca Float.
module Lab
  module Qc
    module Decimal
      TYPED = /\A-?\d{1,9}(,\d{1,4})?\z/
      HL7 = /\A-?\d{1,9}(\.\d{1,4})?\z/

      module_function

      def typed(raw) = raw.is_a?(String) && raw.strip.match?(TYPED) ? BigDecimal(raw.strip.tr(",", ".")) : nil
      def hl7(raw) = raw.is_a?(String) && raw.strip.match?(HL7) ? BigDecimal(raw.strip) : nil

      def out(number)
        return nil if number.nil?

        BigDecimal(number.to_s).to_s("F").sub(/\.0\z/, "")
      end
    end
  end
end
