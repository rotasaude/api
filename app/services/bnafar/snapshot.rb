# Fotografia de estoque do dia R (módulo 27b; Valores 5 e 6; Review Focus 1):
# o saldo por (local, lote) dos domínios ligados, somando os movimentos
# CRIADOS antes do corte. O `recorded_at` pode ser retroativo (app de campo
# offline, `Ledger.record!(at:)`): o movimento criado em R+1 com a data de R não
# entra na posição de R (vai na de R+1, e a saída dele na remessa de R+1), e
# nada sai duas vezes nem some. Em trânsito fica fora sozinho: a transferência
# tira do origem no envio (`transfer_out`) e só põe no destino no recebimento
# (`transfer_in`). Saldo zerado (ou negativo) fica fora.
#
# Leitura pura: `domains` (Stock::Domain) e `cutoff` (Time; para R, o início de
# R+1 no fuso da cidade) chegam calculados (os interruptores se leem fora da
# transação da cidade). `reference_on` só identifica o dia; o corte é `cutoff`.
#
# -> [Row] ordenadas por (CNES, item, lote). `quantity` é a quantidade na
# unidade BNAFAR (Bnafar::Units: a vacina em frascos), ou nil se não for inteira
# (pendência `fractional_balance`). O local sem CNES entra com `cnes` nil
# (pendência `location_without_cnes`): quem filtra é o chamador, pelas
# Pendencies. A posição é por (CNES, item): `groups`.
module Bnafar
  module Snapshot
    Row = Data.define(:location, :cnes, :type, :item_key, :item_label, :lot, :quantity)

    LOCATION_KINDS = {
      Stock::Domain::MEDICATION => %w[central unit],
      Stock::Domain::IMMUNOBIOLOGICAL => Stock::Domain::IMMUNOBIOLOGICAL_LOCATION_KINDS,
      Stock::Domain::VECTOR_CONTROL => Stock::Domain::VECTOR_CONTROL_LOCATION_KINDS
    }.freeze

    module_function

    def call(reference_on:, domains:, cutoff:)
      raise ArgumentError, "reference_on is required" if reference_on.nil?

      kinds = location_kinds(domains)
      return [] if kinds.empty?

      balances = StockMovement.joins(:stock_location).where(stock_locations: { kind: kinds })
                              .where(stock_movements: { created_at: ...cutoff })
                              .group(:stock_location_id, :stock_lot_id)
                              .having("SUM(stock_movements.quantity) > 0")
                              .sum(:quantity)
      return [] if balances.empty?

      locations = StockLocation.includes(:health_unit).where(id: balances.keys.map(&:first).uniq).index_by(&:id)
      lots = StockLot.includes(:vector_product).where(id: balances.keys.map(&:last).uniq).index_by(&:id)
      items = Items.new(lots.values)
      rows = balances.map do |(location_id, lot_id), balance|
        location = locations.fetch(location_id)
        lot = lots.fetch(lot_id)
        Row.new(location: location, cnes: location.bnafar_cnes, type: LocationTypes.for(location), item_key: items.key(lot),
                item_label: items.label(lot), lot: lot, quantity: Units.to_bnafar(lot, balance))
      end
      rows.sort_by { |row| [ row.cnes.to_s, row.item_key, row.lot.lot_number, row.location.id ] }
    end

    # { [cnes, item_key] => [Row] }: um registro de posição por par (partido em
    # Limits::ITEMS_PER_RECORD pelo Build).
    def groups(rows) = rows.group_by { |row| [ row.cnes, row.item_key ] }

    # Tipos de local (`stock_locations.kind`) dos domínios.
    def location_kinds(domains) = Array(domains).flat_map { |domain| LOCATION_KINDS.fetch(domain) }.uniq
  end
end
