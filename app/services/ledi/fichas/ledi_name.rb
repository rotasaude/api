# Nome na ficha de cadastro (módulo 24a; vendor/ledi/8.7.0/docs/validar_nome.html,
# regras 4 e 5): letras romanas, os acentos gráficos agudo, circunflexo, til e
# trema, o apóstrofo e maiúsculas. O paciente guarda o nome como digitado (a
# cedilha é aceita: GONÇALVES); só a ficha converte:
#   - Ç → C; outro diacrítico sai (À → A); acento gráfico só sobre vogal
#     (Ñ → N: acento gráfico do português é de vogal);
#   - hífen e qualquer outro caractere fora do conjunto → espaço;
#   - apóstrofo tipográfico (’ ‘) → apóstrofo reto (');
#   - espaços colapsados, maiúsculas, NFC.
# A recusa do nome (regras 1, 2, 3, 6 e 7) é do TerritoryRegistry::Dictionary.
module Ledi
  module Fichas
    module LediName
      MARKS = "́̂̃̈".freeze
      VOWELS = "AEIOUaeiou".freeze
      APOSTROPHES = /[’‘]/

      module_function

      def call(value)
        return nil if value.blank?

        text = value.to_s.unicode_normalize(:nfd).gsub(APOSTROPHES, "'")
        text = text.gsub(/(.)(\p{Mn}+)/) { "#{::Regexp.last_match(1)}#{marks(::Regexp.last_match(1), ::Regexp.last_match(2))}" }
        text = text.gsub(/[^A-Za-z'#{MARKS}]/, " ").gsub(/(?<![A-Za-z'])[#{MARKS}]+/, "")
        text.squish.upcase.unicode_normalize(:nfc).presence
      end

      # Mantém só o primeiro acento gráfico oficial, e só sobre vogal.
      def marks(base, combining)
        return "" unless VOWELS.include?(base)

        combining.chars.find { |mark| MARKS.include?(mark) }.to_s
      end
      private_class_method :marks
    end
  end
end
