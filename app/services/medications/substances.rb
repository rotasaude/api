# Marcas de antimicrobiano (RDC 471/2021) e de controlado (Portaria 344/1998)
# pelas listas da Anvisa importadas (ADR 0033). Casamento por nome
# normalizado, palavra inteira no começo do ingrediente ("CIPROFLOXACINO"
# casa "CIPROFLOXACINO CLORIDRATO"); em associação, qualquer ingrediente
# marca; a lista de controle mais restritiva vence (A1 < … < C5). O texto
# livre da receita é varrido por palavra inteira.
module Medications
  module Substances
    # anticonvulsant (ADR 0034): padrão false — o 19c cria Flags com três chaves.
    Flags = Data.define(:antimicrobial, :controlled, :controlled_list, :anticonvulsant) do
      def initialize(antimicrobial:, controlled:, controlled_list:, anticonvulsant: false) = super
    end
    NONE = Flags.new(antimicrobial: false, controlled: false, controlled_list: nil)

    module_function

    def key(name) = I18n.transliterate(name.to_s).upcase.gsub(/[^A-Z0-9 ]/, " ").squish

    def matcher(release = AnvisaListRelease.current)
      return Matcher.new(antimicrobials: [], controlled: {}) unless release

      rows = AnvisaListSubstance.where(release_id: release.id).pluck(:kind, :substance_key, :controlled_list)
      Matcher.new(antimicrobials: rows.select { |kind, *| kind == "antimicrobial" }.map(&:second),
                  controlled: rows.select { |kind, *| kind == "controlled" }.to_h { |_kind, substance, list| [ substance, list ] },
                  anticonvulsants: rows.select { |kind, *| kind == "anticonvulsant" }.map(&:second))
    end

    # Reaplica as marcas a todo o catálogo (depois de importar listas ou itens).
    def apply_to_catalog!(matcher)
      changed = 0
      MedicationCatalogItem.find_each do |item|
        flags = matcher.flags_for(item.ingredients)
        current = [ item.antimicrobial, item.controlled, item.controlled_list, item.anticonvulsant ]
        next if current == [ flags.antimicrobial, flags.controlled, flags.controlled_list, flags.anticonvulsant ]

        item.update!(antimicrobial: flags.antimicrobial, controlled: flags.controlled, controlled_list: flags.controlled_list,
                     anticonvulsant: flags.anticonvulsant)
        changed += 1
      end
      changed
    end

    class Matcher
      def initialize(antimicrobials:, controlled:, anticonvulsants: [])
        @antimicrobials = antimicrobials.map { |name| Substances.key(name) }.uniq
        @controlled = controlled.transform_keys { |name| Substances.key(name) }
        @anticonvulsants = anticonvulsants.map { |name| Substances.key(name) }.uniq
      end

      def empty? = @antimicrobials.empty? && @controlled.empty?

      def flags_for(ingredients)
        keys = Array(ingredients).map { |name| Substances.key(name) }
        lists = keys.flat_map { |ingredient| @controlled.filter_map { |substance, list| list if starts?(ingredient, substance) } }
        Flags.new(antimicrobial: keys.any? { |ingredient| @antimicrobials.any? { |substance| starts?(ingredient, substance) } },
                  controlled: lists.any?, controlled_list: lists.min,
                  anticonvulsant: keys.any? { |ingredient| @anticonvulsants.any? { |substance| starts?(ingredient, substance) } })
      end

      def scan(text)
        padded = " #{Substances.key(text)} "
        lists = @controlled.filter_map { |substance, list| list if padded.include?(" #{substance} ") }
        Flags.new(antimicrobial: @antimicrobials.any? { |substance| padded.include?(" #{substance} ") },
                  controlled: lists.any?, controlled_list: lists.min,
                  anticonvulsant: @anticonvulsants.any? { |substance| padded.include?(" #{substance} ") })
      end

      def inspect = "#<Medications::Substances::Matcher #{@antimicrobials.size}/#{@controlled.size}/#{@anticonvulsants.size}>"

      private

      def starts?(ingredient, substance) = ingredient == substance || ingredient.start_with?("#{substance} ")
    end
  end
end
