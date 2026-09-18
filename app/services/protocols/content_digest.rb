require "digest"

# Digest do conteúdo de um protocolo (spec de assinaturas §5).
#
# A assinatura vale para o conteúdo EXATO: editar depois de assinar faz o
# digest mudar, e a assinatura antiga deixa de contar sem que nenhuma linha
# seja alterada. Por isso o digest precisa ser estável para o mesmo conteúdo —
# chaves ordenadas em todos os níveis, porque o jsonb do Postgres não guarda a
# ordem em que foram escritas — e sensível a qualquer mudança, inclusive a
# ordem de uma lista (a ordem dos passos é conteúdo).
module Protocols
  module ContentDigest
    module_function

    def call(definition)
      Digest::SHA256.hexdigest(JSON.generate(canonical(definition)))
    end

    def canonical(value)
      case value
      when Hash then value.to_h { |key, inner| [ key.to_s, canonical(inner) ] }.sort.to_h
      when Array then value.map { |inner| canonical(inner) }
      else value
      end
    end
  end
end
