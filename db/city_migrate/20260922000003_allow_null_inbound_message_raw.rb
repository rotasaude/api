# ADR-0014: o `raw` do InboundMessage "vira NULL após a janela" de retenção,
# preservando os metadados para auditoria. O schema inicial de cidade declarou
# a coluna NOT NULL, então o PurgeInboundRawJob levantava NotNullViolation em
# toda execução e o raw (PII, cifrado) nunca era purgado.
#
# O down só é seguro enquanto nenhuma linha foi purgada; depois disso ele
# falha na própria constraint — é o comportamento correto (não há raw para
# devolver).
class AllowNullInboundMessageRaw < ActiveRecord::Migration[8.1]
  def change
    change_column_null :inbound_messages, :raw, true
  end
end
