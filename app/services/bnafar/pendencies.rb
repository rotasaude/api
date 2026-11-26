# O que impede o envio à BNAFAR (módulo 27b; contrato §3; Q2, Q7, Q15, Q16,
# Q21, Q22): calculado na leitura, sem tabela e sem pessoa. Uma pendência por
# (código, local, lote); o item pendente não entra no registro e o resto do
# estabelecimento vai (o Build filtra pelas linhas sem pendência).
#
# Códigos (Bnafar::Catalog::PENDENCY_CODES):
#   - lot_incomplete: `LotFields.missing` (a vacina pelo YAML, Q21), em `fields`;
#   - lot_number_too_long: número do lote acima de LOT_NUMBER_MAX (Q7);
#   - location_without_cnes: a origem, ou o destino da S-T (o local de destino
#     é o da pendência);
#   - product_without_code: medicamento sem `vmp_code` (Q15), vacina sem
#     `obm_vmp`, vetorial sem `catmat_code`;
#   - fractional_balance: quantidade que não fecha na unidade BNAFAR (o
#     imunobiológico fora do YAML não tem frasco: só `product_without_code`);
#   - exit_type_missing: movimento negativo sem tipo DM12;
#   - domain_off: só em `current`, o estoque de um domínio do estoque que não
#     está ligado ao envio.
module Bnafar
  module Pendencies
    Pendency = Data.define(:code, :stock_location_id, :location_name, :item_key, :item_label, :stock_lot_id, :fields)

    module_function

    # `rows`: Snapshot::Row e/ou Exits::Row. -> [Pendency], sem repetição.
    def call(rows:)
      rows = Array(rows)
      return [] if rows.empty?

      items = Items.new(rows.map(&:lot))
      rows.flat_map { |row| for_row(row, items) }.uniq
    end

    # As linhas sem pendência nenhuma (o que o Build monta), com uma leitura só
    # do catálogo. A conta é por linha: a fração de um movimento não segura
    # outro movimento do mesmo lote.
    def clean(rows)
      rows = Array(rows)
      return [] if rows.empty?

      items = Items.new(rows.map(&:lot))
      rows.select { |row| for_row(row, items).empty? }
    end

    # Pendências de agora (Q22; contrato §6 `GET /pharmacy/bnafar/pendencies`):
    # o saldo de agora mais as saídas de ontem e de hoje.
    #   - `domains_all`: os domínios de estoque UTILIZÁVEIS da cidade
    #     (Stock::Domain.usable?), lidos fora da transação da cidade;
    #   - `domains_on`: os domínios ligados ao envio (Bnafar::Gate.domains_enabled),
    #     ou nil com o `bnafar` desligado (Q22): então a conta é feita contra
    #     `domains_all` como se o envio estivesse ligado e o `domain_off` é
    #     omitido. Com uma lista, cada linha de domínio de `domains_all` fora
    #     dela ganha `domain_off` (as outras pendências dela continuam, para a
    #     cidade completar antes de ligar).
    # "Hoje" é o dia de `now` no fuso corrente (o da cidade em CityConnection.with).
    def current(domains_all:, domains_on:, now: Time.current)
      today = now.in_time_zone.to_date
      positions = Snapshot.call(reference_on: today, domains: domains_all, cutoff: now)
      exits = [ today - 1, today ].flat_map do |day|
        Exits.call(day: day, domains: domains_all, from: day.in_time_zone, to: (day + 1).in_time_zone)[:exits]
      end
      found = call(rows: positions + exits)
      return found if domains_on.nil?

      off = Array(domains_all) - Array(domains_on)
      items = Items.new(positions.map(&:lot))
      dark = positions.select { |row| off.include?(Stock::Domain.of_lot(row.lot)) }
                      .map { |row| pendency("domain_off", row.location, row.lot, items) }
      (found + dark).uniq
    end

    def for_row(row, items)
      lot = row.lot
      origin = row.respond_to?(:location) ? row.location : row.movement.stock_location
      found = []
      missing = LotFields.missing(lot, vmp_code: items.vmp(lot))
      found << pendency("lot_incomplete", origin, lot, items, missing) if missing.any?
      found << pendency("lot_number_too_long", origin, lot, items, [ "lot_number" ]) if lot.lot_number.length > Catalog::LOT_NUMBER_MAX
      found << pendency("location_without_cnes", origin, lot, items, [ "cnes" ]) if row.cnes.blank?
      if row.is_a?(Exits::Row)
        destination = row.movement.stock_transfer&.to_location if row.exit_type == Exits::TRANSFER
        found << pendency("location_without_cnes", destination, lot, items, [ "cnes" ]) if destination && row.destination.blank?
        found << pendency("exit_type_missing", origin, lot, items) if row.exit_type.nil?
      end
      code = items.missing_code(lot)
      found << pendency("product_without_code", origin, lot, items, [ code ]) if code
      # Sem o fator (produto fora do YAML) não há fração: a verdade é o
      # `product_without_code` acima, não o `fractional_balance`.
      found << pendency("fractional_balance", origin, lot, items) if row.quantity.nil? && Units.factor(lot)
      found
    end

    def pendency(code, location, lot, items, fields = [])
      Pendency.new(code: code, stock_location_id: location.id, location_name: location.name, item_key: items.key(lot),
                   item_label: items.label(lot), stock_lot_id: lot.id, fields: fields)
    end

    private_class_method :for_row, :pendency
  end
end
