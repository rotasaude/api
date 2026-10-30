# Validade da receita para a farmácia (ADR 0045, Desvio 8; contrato H3): POR
# ITEM, em dia inclusivo no fuso da cidade (a receita vale até o fim do
# `valid_until`; vence no dia seguinte). Os prazos vêm dos parâmetros da
# cidade, lidos na hora (o admin muda e a próxima busca já vale).
module Pharmacy
  module Validity
    module_function

    # -> Date
    #   - receita EXTERNA com item controlado: 30 dias fixos (Portaria 344),
    #     mesmo contínuo e mesmo que alguém tente informar outra data;
    #   - `explicit` (o `valid_until` gravado no conteúdo do 19c) quando existe;
    #   - senão `issued_on` + o prazo da cidade (contínuo ou comum).
    # `issued_on` é a data NA CIDADE (receita emitida às 23:30 em São Paulo é do
    # dia local, não do dia em UTC).
    def item_until(issued_on:, explicit:, continuous:, controlled:, external:, settings:)
      return issued_on + Catalog::CONTROLLED_VALIDITY_DAYS if external && controlled
      return explicit if explicit

      issued_on + (continuous ? settings.continuous_validity_days : settings.common_validity_days)
    end

    # Vencida só no dia SEGUINTE ao `valid_until`. `today` é o dia da cidade.
    def expired?(until_date, today: Time.zone.today) = today > until_date
  end
end
