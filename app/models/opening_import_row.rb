# Linha lida da planilha do saldo inicial (módulo 27b; contrato §5): as onze
# colunas como texto, o local e o item resolvidos, a situação (valid | error)
# com os códigos do Valor 11 e a entrada `opening` que a linha gerou. Só a
# situação (de válida a erro) e a entrada (de NULL a valor) mudam (trigger).
class OpeningImportRow < ApplicationRecord
  STATUSES = %w[valid error].freeze

  belongs_to :opening_import
  belongs_to :stock_location, optional: true
  belongs_to :vector_product, optional: true
  belongs_to :stock_entry, optional: true
end
