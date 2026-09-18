# O contrato entre quem recusa e quem audita a recusa.
#
# Spec §9 exige auditar "uso recusado de token … fora do escopo", e a recusa
# tem DUAS origens, com mecanismos diferentes:
#
#   1. Na ANÁLISE da query, antes de qualquer resolver (`HumanOnly`,
#      `WriteScope`): um token de serviço tentando campo restrito ou mutation.
#      Etiquetada com `TOKEN_SCOPE_REFUSED`.
#   2. Na RESOLUÇÃO de `city(slug:)` (`QueryType#city`, Plano 4/Task 2): um
#      token cujo `city_slugs` não alcança o slug pedido — só se sabe depois
#      que o argumento chega ao resolver, então não há como um analisador (que
#      roda antes de qualquer argumento ser resolvido contra dado) pegar isso.
#      Etiquetada com `CITY_OUT_OF_SCOPE`.
#
# As duas origens gravar diretamente colocaria escrita dentro de um caminho
# que roda em TODA query (inclusive de leitura) ou duplicaria o mecanismo de
# auditoria; então quem recusa só ETIQUETA o erro (`extensions.code` +
# `refusedFields`), e `Maintenance::GraphqlController` lê a etiqueta do
# resultado e grava o evento uma vez, qualquer que seja a origem.
module Maintenance
  module Analyzers
    module Refusal
      CODE = "TOKEN_SCOPE_REFUSED"
      CITY_OUT_OF_SCOPE = "CITY_OUT_OF_SCOPE"
      CODES = [ CODE, CITY_OUT_OF_SCOPE ].freeze
      FIELDS = "refusedFields"

      # Os campos que foram recusados nesta execução, sem repetição — de
      # QUALQUER origem em CODES. Só nome de campo de raiz do schema entra
      # aqui — nunca valor de argumento (o slug de `city(slug:)` NUNCA entra),
      # nunca pedaço de credencial.
      def self.refused_fields(result)
        Array(result["errors"]).filter_map do |error|
          extensions = error["extensions"]
          next unless extensions.is_a?(Hash) && CODES.include?(extensions["code"])

          extensions[FIELDS]
        end.flatten.uniq
      end
    end
  end
end
