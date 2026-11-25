# Corpo de um registro enviado ao SI-BNAFAR (módulo 27b; Valor 7; Q15, Q21;
# manual v1.25 e Postman da homologação). Puro sobre as linhas já lidas
# (Snapshot::Row, Exits::Row); só lê o catálogo da plataforma e o YAML. Nenhum
# dado de pessoa.
#
# Item: todas as chaves sempre presentes (achado 12 da pesquisa):
#   - `numero`: CATMAT no medicamento e no vetorial; "" na vacina;
#   - `terminologia`: OBM no medicamento e na vacina; CATMAT no vetorial;
#   - `codigoAmpp` do lote (ou null); `codigoVmp` do catálogo ou do YAML;
#   - `cnpjFabricante`: o do lote; na vacina o do fabricante no YAML pela
#     `manufacturer_key` (Q21); null no internacional, que vai pelo nome em
#     `nomeFabricanteInternacional` (Q15);
#   - `valorUnitario`: número com duas casas e ponto (centavos / 100; o JSON
#     não guarda o zero à direita: 1990 → 19.9);
#   - `iums`: [{ ium }] ou [].
# O chamador (Build) só monta linhas sem pendência.
module Bnafar
  module Payload
    module_function

    # Um registro de posição: (CNES, item) com um item por lote de `rows`
    # (`codigoOrigem` = id do lote; o mesmo lote em dois locais do CNES soma).
    def position(cnes:, type:, reference_on:, origin_code:, rows:)
      rows = Array(rows)
      items = Items.new(rows.map(&:lot))
      per_lot = rows.group_by { |row| row.lot.id }.map do |lot_id, same|
        item(same.first.lot, quantity: same.sum(&:quantity), origin: lot_id, items: items)
      end
      { "estabelecimento" => { "cnes" => cnes, "tipo" => type },
        "caracterizacao" => { "codigoOrigem" => origin_code, "dataPosicaoEstoque" => reference_on.iso8601 },
        "itens" => per_lot }
    end

    # Um registro de saída: um movimento. `dataSaida` = o dia (no fuso
    # corrente, o da cidade) em que o movimento foi CRIADO (Valor 6).
    def exit(row, origin_code:)
      movement = row.movement
      items = Items.new([ row.lot ])
      { "estabelecimento" => { "cnes" => row.cnes, "tipo" => row.type },
        "caracterizacao" => { "codigoOrigem" => origin_code, "dataSaida" => movement.created_at.in_time_zone.to_date.iso8601,
                              "estabelecimentoDestino" => row.destination, "tipoSaida" => row.exit_type },
        "itens" => [ item(row.lot, quantity: row.quantity, origin: movement.id, items: items) ] }
    end

    def item(lot, quantity:, origin:, items:)
      vaccine = lot.immunobiological?
      vector = lot.vector_control?
      { "codigoOrigem" => origin,
        "numero" => vaccine ? "" : items.catmat(lot).to_s,
        "terminologia" => vector ? "CATMAT" : "OBM",
        "codigoAmpp" => lot.ampp_code,
        "codigoVmp" => items.vmp(lot),
        "registroAnvisa" => lot.anvisa_registration,
        "tipoProduto" => ProductTypes.for(lot.health_program),
        "lote" => lot.lot_number,
        "dataValidade" => lot.expires_on.iso8601,
        "cnpjFabricante" => manufacturer_cnpj(lot, items),
        "nomeFabricanteInternacional" => lot.manufacturer_international ? lot.manufacturer : nil,
        "quantidade" => quantity,
        "valorUnitario" => lot.unit_price_cents && (lot.unit_price_cents / 100.0).round(2),
        "siglaProgramaSaude" => lot.health_program,
        "iums" => Array(lot.ium).map { |ium| { "ium" => ium } } }
    end

    def manufacturer_cnpj(lot, items)
      return nil if lot.manufacturer_international
      return lot.manufacturer_cnpj unless lot.immunobiological?

      items.vaccine(lot)&.manufacturer(lot.manufacturer_key)&.cnpj
    end

    private_class_method :item, :manufacturer_cnpj
  end
end
