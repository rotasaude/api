# Analisador da descrição semiestruturada do CATMAT classe 6505 (ADR 0033;
# spec §3). Entende o recorte que a APS prescreve: princípio ativo (o nome do
# PDM, mais os associados), concentração, forma e unidade. O resto vai a
# revisão (parse_status review → hidden) com o motivo — nunca um palpite.
# Sobre os 6.778 itens reais de 2026-10-09: 4.098 ok, 2.680 em revisão.
module Medications
  module Catmat
    module DescriptionParser
      Parsed = Data.define(:active_ingredient, :strength, :dosage_form, :unit, :parse_status, :review_reason) do
        def ok? = parse_status == "ok"
      end

      # Vírgula seguida de "CHAVE:" (maiúscula, com acento, espaço, ponto e um
      # número no fim). Vírgula dentro de valor ("SOLUÇÃO ORAL, GOTAS") não é
      # seguida de chave e não divide.
      SPLIT = /,\s*(?=[A-ZÀ-Ü][A-ZÀ-Ü .]*?(?:\s\d)?\s*:)/
      STRENGTH_KEYS = %w[CONCENTRACAO DOSAGEM TEOR].freeze
      # "DOSAGEM COMPRIMIDO: 500 MG": a chave traz a forma.
      STRENGTH_WITH_FORM = /\ADOSAGEM (COMPRIMIDO|CAPSULA|DRAGEA|SOLUCAO ORAL|SUSPENSAO ORAL|XAROPE)\z/
      FORM_KEYS = [ "FORMA FARMACEUTICA", "APRESENTACAO", "USO", "TIPO USO", "APLICACAO", "INDICACAO",
                    "TIPO MEDICAMENTO" ].freeze
      ASSOCIATION_KEYS = [ "COMPOSICAO", "PRINCIPIO ATIVO", "APRESENTACAO" ].freeze
      VARIANT_KEYS = %w[TIPO ORIGEM].freeze
      EXTRA_KEYS = [ "CARACTERISTICA ADICIONAL", "CARACTERISTICAS ADICIONAIS", "ADICIONAL" ].freeze
      ASSOCIATION = /\AASSOC(?:IAD[AO]S?|\.)?\s*(?:COM|AO|AOS|A|AS|À|ÀS|E)?\s+/i
      COMPONENT = %r{\A(\d[\d.]*(?:,\d+)?)\s*(MCG|MG|G|UI|U|MEQ|MMOL|ML|%)(?:\s*/\s*(ML|G|DOSE|L))?\z}i
      UNITS = { "MCG" => "mcg", "MG" => "mg", "G" => "g", "UI" => "UI", "U" => "U", "MEQ" => "mEq", "MMOL" => "mmol",
                "ML" => "mL", "%" => "%" }.freeze
      PER = { "ML" => "mL", "G" => "g", "DOSE" => "dose", "L" => "L" }.freeze
      MANIPULATED = /MANIPULAD/i

      module_function

      def call(pdm_name, description)
        head, *pairs = description.to_s.strip.split(SPLIT)
        name = (pdm_name.to_s.strip.presence || head.to_s.strip).squeeze(" ")
        fields = pairs.map do |pair|
          key, value = pair.split(":", 2)
          [ normalize_key(key), key.to_s.strip.squeeze(" "), value.to_s.strip.squeeze(" ") ]
        end
        return review(name, "manipulated") if fields.any? { |_key, _original, value| value.match?(MANIPULATED) }

        ingredients = [ name ]
        strength = nil
        form = nil
        fields.each do |key, original, value|
          if STRENGTH_KEYS.include?(key)
            return review(name, "duplicated_strength") if strength

            strength = value
          elsif key.match?(STRENGTH_WITH_FORM)
            return review(name, "duplicated_strength") if strength || form

            strength = value
            form = original.sub(/\ADOSAGEM\s+/i, "")
          elsif ASSOCIATION_KEYS.include?(key) && strength.nil? && strength?(value)
            strength = value
          elsif ASSOCIATION_KEYS.include?(key) && value.match?(ASSOCIATION)
            ingredients.concat(value.sub(ASSOCIATION, "").split(/\s*(?:,|\+|\sE\s)\s*/i).map(&:strip).reject(&:empty?))
          elsif FORM_KEYS.include?(key)
            return review(name, "duplicated_form") if form

            form = value
          elsif VARIANT_KEYS.include?(key)
            ingredients[0] = "#{name} #{value}"
          elsif !EXTRA_KEYS.include?(key)
            return review(name, "unknown_field")
          end
        end
        return review(name, "missing_strength") unless strength

        components = strength.split(/\s*\+\s*/).map(&:strip)
        matches = components.map { |component| component.match(COMPONENT) }
        return review(name, "unparsed_strength") if matches.any?(&:nil?)
        return review(name, "ingredient_count") if components.size != ingredients.size

        units = matches.map { |m| [ UNITS.fetch(m[2].upcase), m[3] && PER.fetch(m[3].upcase) ].compact.join("/") }.uniq
        Parsed.new(active_ingredient: ingredients.join(" + "),
                   strength: components.map { |c| c.upcase.gsub(/(\d)\s*([A-Z%])/, '\1 \2').gsub(%r{\s*/\s*}, "/") }.join(" + "),
                   dosage_form: form&.downcase, unit: units.one? ? units.first : nil, parse_status: "ok", review_reason: nil)
      end

      def strength?(value) = value.split(/\s*\+\s*/).all? { |component| component.strip.match?(COMPONENT) }

      def normalize_key(key) = I18n.transliterate(key.to_s).upcase.sub(/\s+\d+\z/, "").squeeze(" ").strip

      def review(name, reason)
        Parsed.new(active_ingredient: name, strength: nil, dosage_form: nil, unit: nil, parse_status: "review",
                   review_reason: reason)
      end
      private_class_method :strength?, :normalize_key, :review
    end
  end
end
