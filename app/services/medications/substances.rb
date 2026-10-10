# Marcas de antimicrobiano (RDC 471/2021) e de controlado (Portaria 344/1998)
# pelas listas da Anvisa importadas (ADR 0033). Casamento por nome
# normalizado, palavra inteira no começo do ingrediente ("CIPROFLOXACINO"
# casa "CIPROFLOXACINO CLORIDRATO"); em associação, qualquer ingrediente
# marca; a lista de controle mais restritiva vence (A1 < … < C5). O texto
# livre da receita é varrido por palavra inteira.
module Medications
  module Substances
    Flags = Data.define(:antimicrobial, :controlled, :controlled_list)
    NONE = Flags.new(antimicrobial: false, controlled: false, controlled_list: nil)

    module_function

    def key(name) = I18n.transliterate(name.to_s).upcase.gsub(/[^A-Z0-9 ]/, " ").squish

    def matcher(release = AnvisaListRelease.current)
      return Matcher.new(antimicrobials: [], controlled: {}) unless release

      rows = AnvisaListSubstance.where(release_id: release.id).pluck(:kind, :substance_key, :controlled_list)
      Matcher.new(antimicrobials: rows.select { |kind, *| kind == "antimicrobial" }.map(&:second),
                  controlled: rows.select { |kind, *| kind == "controlled" }.to_h { |_kind, substance, list| [ substance, list ] })
    end

    # Reaplica as marcas a todo o catálogo (depois de importar listas ou itens).
    def apply_to_catalog!(matcher)
      changed = 0
      MedicationCatalogItem.find_each do |item|
        flags = matcher.flags_for(item.ingredients)
        next if [ item.antimicrobial, item.controlled, item.controlled_list ] == [ flags.antimicrobial, flags.controlled, flags.controlled_list ]

        item.update!(antimicrobial: flags.antimicrobial, controlled: flags.controlled, controlled_list: flags.controlled_list)
        changed += 1
      end
      changed
    end

    class Matcher
      def initialize(antimicrobials:, controlled:)
        @antimicrobials = antimicrobials.map { |name| Substances.key(name) }.uniq
        @controlled = controlled.transform_keys { |name| Substances.key(name) }
      end

      def empty? = @antimicrobials.empty? && @controlled.empty?

      def flags_for(ingredients)
        keys = Array(ingredients).map { |name| Substances.key(name) }
        lists = keys.flat_map { |ingredient| @controlled.filter_map { |substance, list| list if starts?(ingredient, substance) } }
        Flags.new(antimicrobial: keys.any? { |ingredient| @antimicrobials.any? { |substance| starts?(ingredient, substance) } },
                  controlled: lists.any?, controlled_list: lists.min)
      end

      def scan(text)
        padded = " #{Substances.key(text)} "
        lists = @controlled.filter_map { |substance, list| list if padded.include?(" #{substance} ") }
        Flags.new(antimicrobial: @antimicrobials.any? { |substance| padded.include?(" #{substance} ") },
                  controlled: lists.any?, controlled_list: lists.min)
      end

      def inspect = "#<Medications::Substances::Matcher #{@antimicrobials.size}/#{@controlled.size}>"

      private

      def starts?(ingredient, substance) = ingredient == substance || ingredient.start_with?("#{substance} ")
    end
  end
end
