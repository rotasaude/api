# O contrato entre os analisadores de escopo e quem audita a recusa.
#
# Spec §9 exige auditar "uso recusado de token … fora do escopo", e a recusa é
# observada na análise da query — antes de qualquer resolver. Gravar dali
# colocaria escrita dentro de um passo que roda em TODA query, inclusive de
# leitura; então o analisador só ETIQUETA o erro, e `Maintenance::GraphqlController`
# lê a etiqueta do resultado e grava o evento uma vez.
module Maintenance
  module Analyzers
    module Refusal
      CODE = "TOKEN_SCOPE_REFUSED"
      FIELDS = "refusedFields"

      # Os campos que os analisadores recusaram nesta execução, sem repetição.
      # Só nome de campo de raiz do schema entra aqui — nunca valor de
      # argumento, nunca pedaço de credencial.
      def self.refused_fields(result)
        Array(result["errors"]).filter_map do |error|
          extensions = error["extensions"]
          next unless extensions.is_a?(Hash) && extensions["code"] == CODE

          extensions[FIELDS]
        end.flatten.uniq
      end
    end
  end
end
