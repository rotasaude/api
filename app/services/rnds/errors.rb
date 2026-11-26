# Erros do transporte da RNDS (módulo 29, Desvio 14) e a limpeza do texto que
# a RNDS devolve. Mensagens NOSSAS: nunca a da exceção de rede (traz URL),
# nunca o corpo da resposta sem passar por `sanitize`.
module Rnds
  module Errors
    MAX = 200
    DIGITS = /\d{11,}/
    FORMATTED_CPF = /\d{3}\.\d{3}\.\d{3}-\d{2}/
    # Código de recusa da RNDS (EHR-ERR825, EDS-MSG009...): CODE confere um código
    # inteiro; SCAN o acha dentro do diagnóstico (o IG não fixa o texto, só o código).
    CODE = /\A(EHR-ERR|EDS-MSG)\d{3}\z/
    SCAN = /(?:EHR-ERR|EDS-MSG)\d{3}(?!\d)/
    NO_CODE = "rejected".freeze

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

    # Só os códigos do diagnóstico; nunca o texto. Procura no diagnóstico
    # INTEIRO (26c, Task 12): um código depois do corte de 200 caracteres do
    # `sanitize` (o do texto gravado/mostrado) ainda classifica a recusa.
    # Sem código: ["rejected"].
    def codes(text)
      found = text.to_s.dup.force_encoding("UTF-8").scrub.scan(SCAN).uniq
      found.presence || [ NO_CODE ]
    end
  end
end
