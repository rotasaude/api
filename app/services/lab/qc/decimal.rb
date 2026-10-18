# Números do CIQ, do CEQ e do estoque (C-E9): no JSON e na HL7 (NM) o decimal é
# string com PONTO, até 9 inteiros e 4 casas; vírgula, espaço ou outro formato
# → nil (o api responde invalid_value). Saída com ponto e sem zeros à direita.
# Sempre BigDecimal, nunca Float.
module Lab
  module Qc
    module Decimal
      FORMAT = /\A-?\d{1,9}(\.\d{1,4})?\z/

      module_function

      def json(raw) = raw.is_a?(String) && raw.match?(FORMAT) ? BigDecimal(raw) : nil
      def hl7(raw) = json(raw)

      def out(number)
        return nil if number.nil?

        BigDecimal(number.to_s).to_s("F").sub(/\.0\z/, "")
      end
    end
  end
end
