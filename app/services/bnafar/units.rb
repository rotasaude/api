# Unidade de fornecimento da BNAFAR (módulo 27b, Valor 5): medicamento e vetorial em 1; imunobiológico
# em `doses_per_vial` (o lote conta doses, a BNAFAR conta frascos). Puro: sem banco.
module Bnafar
  module Units
    module_function

    # `lot_or_product` responde a `doses_per_vial` (produto) ou é um lote (`item_kind`,
    # `immunobiological_code`). nil quando o imunobiológico não está no YAML (o código
    # saiu ou mudou): o frasco é desconhecido e quem chama decide a recusa — a
    # posição e as saídas viram a pendência `product_without_code` (sem obm_vmp),
    # a saída externa recusa o lote (`invalid_items`). Nunca levanta: um lote não
    # derruba o envio da cidade inteira.
    def factor(lot_or_product)
      return nil if lot_or_product.nil?
      return Integer(lot_or_product.doses_per_vial) if lot_or_product.respond_to?(:doses_per_vial)
      return 1 unless lot_or_product.item_kind.to_s == "immunobiological"

      Vaccination::Immunobiologicals.find(lot_or_product.immunobiological_code)&.doses_per_vial
    end

    # Quantidade do lote na unidade BNAFAR; nil se não for inteira (-> `fractional_balance`)
    # ou se o produto não for conhecido (`factor` nil -> `product_without_code`).
    def to_bnafar(lot, quantity)
      unit = factor(lot)
      return nil unless unit

      ratio = quantity.to_d / unit
      ratio.frac.zero? ? ratio.to_i : nil
    end

    # Quantidade do estoque; nil com o produto desconhecido (o Validator da planilha
    # já recusa antes: `product_unknown`).
    def from_bnafar(lot_or_product, quantity)
      unit = factor(lot_or_product)
      unit && BigDecimal(quantity.to_i) * unit
    end
  end
end
