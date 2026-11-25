# Evidência da homologação (módulo 27b, Task 8): o cURL de cada chamada com o
# status e o corpo da resposta, para anexar ao pedido de homologação. Só em
# homologação (em produção devolve ""). O token e a senha NUNCA entram: o cURL
# leva `<TOKEN>` e `<USUARIO>:<SENHA>`. O corpo da resposta passa por
# `Rnds::Errors.sanitize` (sem CPF/CNS, uma linha, 200 caracteres).
module Bnafar
  module Evidence
    TOKEN_FIELD = /("(?:access_token|refresh_token|id_token|token)"\s*:\s*)"[^"]*"/i
    JWT = /eyJ[\w-]+\.[\w-]+\.?[\w-]*/

    module_function

    def curl(method:, url:, body:, status: nil, response: nil, environment: Environment.current)
      return "" unless environment == "homologation"

      lines = [ "curl -X #{method.to_s.upcase} '#{quote(url)}'",
                "  -H 'Authorization: jwt <TOKEN>'",
                "  -H 'Content-Type: application/json'" ]
      lines << "  -d '#{quote(JSON.generate(body))}'" unless body.nil?
      render(lines, status, response)
    end

    # Sem o corpo da resposta: o do jwtauth é o próprio token (e o JWT leva o usuário).
    def login(url:, status: nil, environment: Environment.current)
      return "" unless environment == "homologation"

      render([ "curl -X POST '#{quote(url)}'", "  -u '<USUARIO>:<SENHA>'" ], status, nil)
    end

    # Corpo da resposta como entra na evidência (Task 11: `{ curl, status, body }`
    # por chamada): sem token, sem CPF/CNS, uma linha, 200 caracteres. "" fora
    # da homologação.
    def response(text, environment: Environment.current)
      return "" unless environment == "homologation"

      Rnds::Errors.sanitize(scrub(text))
    end

    def render(lines, status, response)
      text = lines.join(" \\\n")
      text += "\n# HTTP #{status.to_i}" if status
      text += "\n# #{Rnds::Errors.sanitize(scrub(response))}" if response.present?
      text
    end

    # Nenhum campo de token da resposta chega à evidência, nem um JWT solto.
    def scrub(text)
      text.to_s.gsub(TOKEN_FIELD, '\\1"***"').gsub(JWT, "***")
    end

    def quote(text) = text.to_s.gsub("'", "'\\\\''")
    private_class_method :render, :quote, :scrub
  end
end
