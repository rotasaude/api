# Code 128 da etiqueta (ADR 0037; prova técnica b): só o codificador da barby
# (10 dígitos = conjunto C, 90 módulos); o desenho é nosso, em vetor.
require "barby/barcode/code_128"

module Lab
  module Code128
    module_function

    def encoding(value)
      raise ArgumentError, "código de barras só com dígitos, em número par" unless value.is_a?(String) && value.match?(/\A(\d\d)+\z/)

      Barby::Code128.new(value).encoding
    end
  end
end
