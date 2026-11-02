# Erros do transporte da RNDS (módulo 29, Desvio 14) e a limpeza do texto que
# a RNDS devolve. Mensagens NOSSAS: nunca a da exceção de rede (traz URL),
# nunca o corpo da resposta sem passar por `sanitize`.
module Rnds
  module Errors
    MAX = 200
    DIGITS = /\d{11,}/
    FORMATTED_CPF = /\d{3}\.\d{3}\.\d{3}-\d{2}/

    class Error < StandardError; end
    class NotConfigured < Error; end # URL da plataforma ou credencial da cidade ausentes
    class Unauthorized < Error; end  # a RNDS recusou o certificado, o token ou o envio (401/403)
    class Unavailable < Error; end   # rede, timeout, 5xx, resposta inválida

    module_function

    # Texto da RNDS que pode chegar a registro: UTF-8 válido, uma linha, sem
    # CPF/CNS (11+ dígitos ou CPF formatado) e com no máximo 200 caracteres.
    def sanitize(text)
      text.to_s.dup.force_encoding("UTF-8").scrub.gsub(FORMATTED_CPF, "***").gsub(DIGITS, "***").squish.first(MAX)
    end
  end
end
