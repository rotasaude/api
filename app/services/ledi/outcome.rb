# O que uma resposta do recebimento do PEC significa para a fila (spec §6.4).
# Duplicidade e sessão expirada seguem o que a prova técnica observou
# (config/ledi/pec_observations.yml).
module Ledi
  module Outcome
    module_function

    # Só 400 recusa; sessão expirada pede relogin; todo o resto tenta de novo.
    def classify(status, body)
      return :accepted if (200..299).cover?(status)
      return :unauthorized if Ledi::Observations.session_expired_statuses.include?(status)
      return :retry unless status == 400

      # PROVISÓRIO (rotasaude/api#41): o marcador de duplicidade ainda não foi
      # observado no PEC real; sem ele, todo 400 é recusa.
      marker = Ledi::Observations.duplicate_marker
      marker && body.to_s.include?(marker) ? :accepted : :rejected
    end

    # Texto legível do corpo de um 400: descricaoErro + errosValidacao achatados
    # ("chave: mensagem", chaves aninhadas com "."), separados por "; ". Corpo
    # que não é JSON objeto volta cru. Quem grava passa por ErrorText.sanitize.
    def message(body)
      parsed = JSON.parse(body.to_s)
      return body.to_s unless parsed.is_a?(Hash)

      parts = [ parsed["descricaoErro"].presence&.to_s ]
      parts.concat(flatten(parsed["errosValidacao"], nil))
      parts = parts.compact
      parts.empty? ? body.to_s : parts.join("; ")
    rescue JSON::ParserError
      body.to_s
    end

    def flatten(node, prefix)
      case node
      when Hash then node.flat_map { |k, v| flatten(v, [ prefix, k ].compact.join(".")) }
      when Array then node.flat_map { |v| flatten(v, prefix) }
      when nil then []
      else [ prefix ? "#{prefix}: #{node}" : node.to_s ]
      end
    end
    private_class_method :flatten
  end
end
