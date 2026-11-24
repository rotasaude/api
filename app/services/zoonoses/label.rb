# Etiqueta da coleta de sorologia canina (módulo 35b, ADR 0054; contrato §6,
# Q21), feita pelo api: `LV-<ano>-<6 primeiros hex do id do inquérito, em
# maiúsculas>-<seq 4>` ou, fora de inquérito, `LV-<ano>-AVUL-<seq 4>`
# (Catalog::LABEL). A sequência é a do prefixo (o inquérito e o ano, ou o ano
# avulso): a maior gravada + 1, lida sob pg_advisory_xact_lock da chave do
# prefixo, então duas coletas ao mesmo tempo nunca saem com a mesma etiqueta.
# A trava é da transação: quem chama grava a coleta na mesma transação.
module Zoonoses
  module Label
    LOOSE = "AVUL".freeze

    module_function

    # -> String
    def next!(survey:, year:)
      connection = LeishTest.connection
      raise ArgumentError, "Zoonoses::Label.next! fora de transação" unless connection.transaction_open?

      prefix = "LV-#{year}-#{survey ? survey.id.delete('-')[0, 6].upcase : LOOSE}"
      # pg_advisory_xact_lock devolve void: execute, nunca select_value.
      connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote("leish_label:#{prefix}")}))")
      last = LeishTest.where("label LIKE ?", "#{prefix}-%").maximum(:label)
      "#{prefix}-#{format('%04d', last ? last.split('-').last.to_i + 1 : 1)}"
    end
  end
end
