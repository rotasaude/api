# Chave cega de duplicados (ADR 0042; Desvio 1 do plano do 24a): nome
# normalizado + nascimento, gravada em patients.match_key com cifra
# determinística (a mesma técnica de patients.cpf) — busca por igualdade sem
# texto claro no banco, e a rotação de chave regrava sozinha. O nome da mãe
# fica de fora (pode faltar): Duplicates filtra os candidatos já decifrados.
module Patients
  module MatchKey
    module_function

    # "<nome normalizado>|<AAAA-MM-DD>", ou nil sem nome ou sem data válida.
    def for(full_name, birth_date)
      name = normalize(full_name)
      date = iso_date(birth_date)
      name && date ? "#{name}|#{date}" : nil
    end

    # Sem acento, minúsculas, só [a-z ], espaços colapsados.
    def normalize(text)
      return nil if text.blank?

      I18n.transliterate(text.to_s, locale: :en).downcase.gsub(/[^a-z ]/, "").squish.presence
    end

    def iso_date(value)
      return value.iso8601 if value.is_a?(Date)
      return nil unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value.to_s).iso8601
    rescue Date::Error
      nil
    end
  end
end
