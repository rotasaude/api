# Linha recusada da carga OBM (Q47): posição e código, nunca o conteúdo da célula.
module Maintenance
  module Types
    class ObmImportRejectedLineType < BaseObject
      description "Linha recusada do arquivo OBM: número da linha, coluna do mapa e código curto. Nunca o conteúdo da célula."

      field :line, Integer, null: false
      field :column, String, null: true
      field :code, String, null: false
    end
  end
end
