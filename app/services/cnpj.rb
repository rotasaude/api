# CNPJ com dígitos verificadores (módulo 11, pesos 2..9 da direita para a
# esquerda). Desde julho de 2026 a Receita emite CNPJ alfanumérico (IN RFB
# 2.229/2024): os 12 primeiros caracteres em [0-9A-Z], os 2 últimos dígitos;
# o valor de cada caractere é o código ASCII − 48 (o numérico é o caso
# particular). Exemplo oficial: 12.ABC.345/01DE-35.
module Cnpj
  WEIGHTS = (2..9).to_a.freeze
  FORMAT = /\A[0-9A-Z]{12}[0-9]{2}\z/

  module_function

  def normalize(value)
    return nil unless value.is_a?(String)

    raw = value.upcase.gsub(%r{[.\-/\s]}, "")
    return nil unless raw.match?(FORMAT) && raw.chars.uniq.size > 1

    raw == with_check_digits(raw[0, 12]) ? raw : nil
  end

  def with_check_digits(base12)
    first = digit(base12)
    "#{base12}#{first}#{digit("#{base12}#{first}")}"
  end

  def display(cnpj) = "#{cnpj[0, 2]}.#{cnpj[2, 3]}.#{cnpj[5, 3]}/#{cnpj[8, 4]}-#{cnpj[12, 2]}"

  def digit(chars)
    sum = chars.chars.reverse.each_with_index.sum { |char, index| (char.ord - 48) * WEIGHTS[index % WEIGHTS.size] }
    rest = sum % 11
    rest < 2 ? 0 : 11 - rest
  end
  private_class_method :digit
end
