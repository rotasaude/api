# Unidade de dispensação do item (módulo 27a, ADR 0045, Desvio 1).
# `medication_catalog_items.unit` é a unidade da CONCENTRAÇÃO ("mg"); a de
# dispensação ("comprimido", "frasco") sai do dosage_form pela tabela
# config/pharmacy/dispensing_units.yml e é gravada no lote na primeira entrada
# (stock_lots.dispensing_unit): mudar a tabela depois não muda o sentido de
# saldo antigo. Fora do lote (busca de item, mínimo sem lote), é esta regra.
module Pharmacy
  module DispensingUnit
    FILE = "config/pharmacy/dispensing_units.yml".freeze

    module_function

    # -> "comprimido" | ... | "unidade"
    def for(catalog_item)
      from_form(catalog_item&.dosage_form)
    end

    def from_form(dosage_form)
      text = " #{normalize(dosage_form)} "
      rule = rules.find { |candidate| candidate[:words].any? { |word| text.include?(word.end_with?(" ") ? " #{word}" : word) } }
      rule ? rule[:unit] : fallback
    end

    def normalize(text) = I18n.transliterate(text.to_s).downcase.squish

    def rules
      @rules ||= config.fetch("rules").map do |rule|
        # Palavra com espaço no fim ("po ") só casa palavra inteira: o texto ganha
        # um espaço de cada lado e a busca leva um à frente.
        { words: rule.fetch("match").map { |word| I18n.transliterate(word).downcase }.uniq.freeze, unit: rule.fetch("unit").freeze }
      end.freeze
    end

    def fallback = config.fetch("fallback")

    def config
      @config ||= YAML.safe_load_file(Rails.root.join(FILE)).freeze
    end
  end
end
