# Etiqueta da coleta de sorologia canina (módulo 35b, ADR 0054; contrato §6,
# Q21, Q36), feita pelo api: `LV-<ano>-<6 primeiros hex do id do inquérito, em
# maiúsculas>-<seq>` ou, fora de inquérito, `LV-<ano>-AVUL-<seq>`
# (Catalog::LABEL). A seq tem ao menos 4 dígitos com zeros à esquerda e cresce
# até 6 (…-9999 → …-10000), sem recomeçar (Q36); passar de 999999 levanta
# Label::Exhausted (quem chama recusa com invalid_request path label). A
# sequência é a do prefixo (o inquérito e o ano, ou o ano avulso): o maior
# sufixo NUMÉRICO gravado + 1 (o máximo léxico poria -9999 acima de -10000),
# lido sob pg_advisory_xact_lock da chave do prefixo, então duas coletas ao
# mesmo tempo nunca saem com a mesma etiqueta. A trava é da transação: quem
# chama grava a coleta na mesma transação.
module Zoonoses
  module Label
    LOOSE = "AVUL".freeze
    MAX_SEQ = 999_999

    # A sequência do prefixo chegou a MAX_SEQ.
    class Exhausted < StandardError; end

    module_function

    # -> String | raise Exhausted
    def next!(survey:, year:)
      connection = LeishTest.connection
      raise ArgumentError, "Zoonoses::Label.next! fora de transação" unless connection.transaction_open?

      prefix = "LV-#{year}-#{survey ? survey.id.delete('-')[0, 6].upcase : LOOSE}"
      # pg_advisory_xact_lock devolve void: execute, nunca select_value.
      connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote("leish_label:#{prefix}")}))")
      # O prefixo só tem dígitos, hex maiúsculo e hífen: nenhum curinga do LIKE.
      last = LeishTest.where("label LIKE ?", "#{prefix}-%").maximum(Arel.sql("split_part(label, '-', 4)::integer"))
      seq = last.to_i + 1
      raise Exhausted, "sequência de etiqueta esgotada para #{prefix}" if seq > MAX_SEQ

      "#{prefix}-#{format('%04d', seq)}"
    end
  end
end
