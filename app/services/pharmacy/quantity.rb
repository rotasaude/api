# Quantidade como no papel (ADR 0045; contrato): só String decimal com ponto,
# até 5 inteiros e 2 casas (`QUANTITY`). Número JSON, vírgula, 3 casas, sinal,
# espaço → nil; nunca arredonda. Saída sempre com duas casas ("30.00").
module Pharmacy
  module Quantity
    module_function

    # -> BigDecimal | nil. Zero só com allow_zero (contagem e recebido).
    # `pattern` mais largo só para SALDO digitado (counted_quantity, até
    # numeric(14,2)): quantidade de movimento fica em QUANTITY.
    def parse(raw, allow_zero: false, pattern: Catalog::QUANTITY)
      return nil unless raw.is_a?(String) && raw.match?(pattern)

      value = BigDecimal(raw)
      return nil if value.zero? && !allow_zero

      value
    end

    # -> "30.00"
    def dump(value)
      value.to_d.round(2).to_s("F").then do |text|
        whole, fraction = text.split(".")
        "#{whole}.#{fraction.to_s.ljust(2, '0')}"
      end
    end
  end
end
