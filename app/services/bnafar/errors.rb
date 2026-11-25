# Erros do transporte do SI-BNAFAR (módulo 27b, Task 8). Mensagens NOSSAS:
# nunca a da exceção de rede (traz URL), nunca o corpo da resposta.
module Bnafar
  module Errors
    class Error < StandardError; end
    class NotConfigured < Error; end # URL da plataforma ou credencial da cidade ausentes
    class Unauthorized < Error; end  # o SI-BNAFAR recusou usuário ou senha (401/403 no jwtauth)
    class Unavailable < Error; end   # rede, timeout, 5xx, resposta inválida
  end
end
