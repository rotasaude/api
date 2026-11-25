# Unidade de fornecimento da BNAFAR (módulo 27b, Valor 5): medicamento e vetorial em 1; imunobiológico
# em `doses_per_vial` (o lote conta doses, a BNAFAR conta frascos). Puro: sem banco.
module Bnafar
  module Units
    module_function

    # `lot_or_product` responde a `doses_per_vial` (produto) ou é um lote (`item_kind`,
    # `immunobiological_code`).
    def factor(lot_or_product)
      return Integer(lot_or_product.doses_per_vial) if lot_or_product.respond_to?(:doses_per_vial)
      return 1 unless lot_or_product.item_kind.to_s == "immunobiological"

      product = Vaccination::Immunobiologicals.find(lot_or_product.immunobiological_code)
      raise KeyError, "immunobiological #{lot_or_product.immunobiological_code.inspect}" unless product

      product.doses_per_vial
    end

    # Quantidade do lote na unidade BNAFAR; nil se não for inteira (-> `fractional_balance`).
    def to_bnafar(lot, quantity)
      ratio = quantity.to_d / factor(lot)
      ratio.frac.zero? ? ratio.to_i : nil
    end

    def from_bnafar(lot_or_product, quantity) = BigDecimal(quantity.to_i) * factor(lot_or_product)
  end
end
