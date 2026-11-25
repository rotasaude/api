# Evidência da homologação (módulo 27b, Task 8): o cURL de cada chamada com o
# status e o corpo da resposta, para anexar ao pedido de homologação. Só em
# homologação (em produção devolve ""). O token e a senha NUNCA entram: o cURL
# leva `<TOKEN>` e `<USUARIO>:<SENHA>`. O corpo da resposta passa por
# `Rnds::Errors.sanitize` (sem CPF/CNS, uma linha, 200 caracteres).
module Bnafar
  module Evidence
    module_function

    def curl(method:, url:, body:, status: nil, response: nil, environment: Environment.current)
      return "" unless environment == "homologation"

      lines = [ "curl -X #{method.to_s.upcase} '#{quote(url)}'",
                "  -H 'Authorization: jwt <TOKEN>'",
                "  -H 'Content-Type: application/json'" ]
      lines << "  -d '#{quote(JSON.generate(body))}'" unless body.nil?
      render(lines, status, response)
    end

    def login(url:, status: nil, response: nil, environment: Environment.current)
      return "" unless environment == "homologation"

      render([ "curl -X POST '#{quote(url)}'", "  -u '<USUARIO>:<SENHA>'" ], status, response)
    end

    def render(lines, status, response)
      text = lines.join(" \\\n")
      text += "\n# HTTP #{status.to_i}" if status
      text += "\n# #{Rnds::Errors.sanitize(response)}" if response.present?
      text
    end

    def quote(text) = text.to_s.gsub("'", "'\\\\''")
    private_class_method :render, :quote
  end
end
