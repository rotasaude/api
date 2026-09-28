require "digest"

# Cartão Nacional de Saúde (spec 2026-09-27-module-10-professionals §3.1).
# Regra única para as duas famílias: 15 dígitos, primeiro em 1, 2, 7, 8 ou 9,
# soma ponderada (pesos 15 a 1) múltipla de 11 — o definitivo (1/2, derivado
# do PIS) é construído para fechar essa soma. Fonte única do modelo e da semente.
module Professionals
  module Cns
    FORMAT = /\A[12789]\d{14}\z/

    module_function

    def valid?(value)
      digits = value.to_s
      return false unless digits.match?(FORMAT)

      weighted_sum(digits).zero?
    end

    # Provisório (prefixo 7) determinístico pela semente, para a semente de dev
    # não duplicar a cada reseed. Quando o dígito verificador daria 10, troca
    # o contador e tenta de novo.
    def generate(seed)
      (0..).each do |attempt|
        body = "7" + Digest::SHA256.hexdigest("#{seed}:#{attempt}").scan(/\d/).join[0, 13].ljust(13, "0")
        check = (11 - (weighted_sum(body + "0"))) % 11
        return body + check.to_s if check < 10
      end
    end

    def mask(value)
      return nil if value.blank?

      "*** **** **** #{value.to_s[-4..]}"
    end

    def weighted_sum(digits)
      digits.chars.each_with_index.sum { |c, i| c.to_i * (15 - i) } % 11
    end
  end
end
