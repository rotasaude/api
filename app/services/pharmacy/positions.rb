# Posição de estoque por (local, item) (ADR 0045; contrato §2, §4 e H10/H12).
# O saldo nunca é coluna: sai de SUM(stock_movements.quantity) agrupado por
# (local, item, lote) em SQL. "Em trânsito" é derivado: a soma de
# `quantity_sent` dos itens de transferências `sent` com destino no local, por
# lote (sem movimento até o recebimento).
#
# Uma posição por (local, item) que tem movimento, lote em trânsito para o
# local ou mínimo cadastrado (> 0); item com mínimo e sem movimento entra com
# saldo 0. Ordem estável por (local, item) com cursor opaco: `next_before` =
# Cursor.encode([location_id, catalog_item_id]) do último da página. Os
# filtros `expiring` e `below_minimum` rodam em SQL ANTES do limite, então a
# página nunca vem curta por causa deles.
#
# `lots[]` traz só lote com saldo > 0 ou em trânsito > 0, em ordem FEFO
# (validade, número, id), cada um com `balance`, `in_transit` e as marcas do
# lote: `expired` (validade < hoje) e `expiring_soon` (não vencido e validade
# <= hoje + expiry_alert_days). Na POSIÇÃO, `expiring_soon` = algum lote com
# saldo > 0 e validade <= hoje + expiry_alert_days (inclui os já vencidos: é o
# que a tela "vencendo e vencidos" lista). `below_minimum` = mínimo > 0 e saldo
# total < mínimo (o mínimo 0 desliga o alerta e vem como `minimum: null`).
#
# Sem dado de paciente.
module Pharmacy
  module Positions
    module_function

    # -> { positions: [<position>], next_before: String | nil }
    # `before` é o cursor JÁ decodificado e validado ([location_id, item_id]).
    def call(location_ids:, limit:, today:, settings:, catalog_item_ids: nil, expiring: false, below_minimum: false, before: nil)
      cutoff = today + settings.expiry_alert_days
      tail = +"SELECT * FROM flagged WHERE TRUE"
      binds = {}
      tail << " AND expiring_soon" if expiring
      tail << " AND below_minimum" if below_minimum
      if before
        tail << " AND (location_id, catalog_item_id) > (CAST(:cursor_location AS uuid), CAST(:cursor_item AS uuid))"
        binds.merge!(cursor_location: before.first, cursor_item: before.last)
      end
      tail << " ORDER BY location_id, catalog_item_id LIMIT :fetch"
      rows = query(tail, location_ids: location_ids, item_ids: catalog_item_ids, cutoff: cutoff, binds: binds.merge(fetch: limit + 1))

      page = rows.first(limit)
      { positions: present(page, today: today, cutoff: cutoff),
        next_before: rows.size > limit ? Cursor.encode([ page.last["location_id"], page.last["catalog_item_id"] ]) : nil }
    end

    # Executa `tail` sobre as CTEs `lots`, `keys`, `positions` e `flagged`
    # (as mesmas para a posição e para os alertas: uma conta só). `lots` =
    # (location_id, catalog_item_id, lot_id, balance, in_transit) por lote.
    # -> Array<Hash> com as linhas cruas.
    def query(tail, location_ids:, item_ids:, cutoff:, binds: {})
      only_items = item_ids ? " AND %<column>s IN (:item_ids)" : ""
      sql = <<~SQL
        WITH balances AS (
          SELECT m.stock_location_id AS location_id, m.catalog_item_id, m.stock_lot_id AS lot_id,
                 SUM(m.quantity) AS balance, 0::numeric AS in_transit
          FROM stock_movements m
          WHERE m.stock_location_id IN (:location_ids)#{format(only_items, column: 'm.catalog_item_id')}
          GROUP BY m.stock_location_id, m.catalog_item_id, m.stock_lot_id
        ), transit AS (
          SELECT t.to_location_id AS location_id, l.catalog_item_id, i.stock_lot_id AS lot_id,
                 0::numeric AS balance, SUM(i.quantity_sent) AS in_transit
          FROM stock_transfer_items i
          JOIN stock_transfers t ON t.id = i.stock_transfer_id
          JOIN stock_lots l ON l.id = i.stock_lot_id
          WHERE t.status = 'sent' AND t.to_location_id IN (:location_ids)#{format(only_items, column: 'l.catalog_item_id')}
          GROUP BY t.to_location_id, l.catalog_item_id, i.stock_lot_id
        ), lots AS (
          SELECT location_id, catalog_item_id, lot_id, SUM(balance) AS balance, SUM(in_transit) AS in_transit
          FROM (SELECT * FROM balances UNION ALL SELECT * FROM transit) joined
          GROUP BY location_id, catalog_item_id, lot_id
        ), keys AS (
          SELECT location_id, catalog_item_id FROM lots
          UNION
          SELECT stock_location_id, catalog_item_id FROM stock_minimums
          WHERE minimum > 0 AND stock_location_id IN (:location_ids)#{format(only_items, column: 'catalog_item_id')}
        ), positions AS (
          SELECT k.location_id, k.catalog_item_id,
                 COALESCE(SUM(l.balance), 0) AS balance,
                 NULLIF(mn.minimum, 0) AS minimum,
                 COALESCE(BOOL_OR(l.balance > 0 AND sl.expires_on <= :cutoff), FALSE) AS expiring_soon
          FROM keys k
          LEFT JOIN lots l ON l.location_id = k.location_id AND l.catalog_item_id = k.catalog_item_id
          LEFT JOIN stock_lots sl ON sl.id = l.lot_id
          LEFT JOIN stock_minimums mn ON mn.stock_location_id = k.location_id AND mn.catalog_item_id = k.catalog_item_id
          GROUP BY k.location_id, k.catalog_item_id, mn.minimum
        ), flagged AS (
          SELECT positions.*, (minimum IS NOT NULL AND balance < minimum) AS below_minimum FROM positions
        )
        #{tail}
      SQL
      values = { location_ids: Array(location_ids), item_ids: Array(item_ids), cutoff: cutoff }.merge(binds)
      StockMovement.connection.select_all(StockMovement.sanitize_sql_array([ sql, values ])).to_a
    end

    # Lotes das posições da página: só com saldo > 0 ou em trânsito > 0.
    def lot_rows(keys)
      return [] if keys.empty?

      connection = StockMovement.connection
      pairs = keys.map { |location, item| "(CAST(#{connection.quote(location)} AS uuid), CAST(#{connection.quote(item)} AS uuid))" }.join(", ")
      query("SELECT * FROM lots WHERE (balance > 0 OR in_transit > 0) AND (location_id, catalog_item_id) IN (#{pairs})",
            location_ids: keys.map(&:first).uniq, item_ids: keys.map(&:last).uniq, cutoff: Time.zone.today)
    end

    # <position> de cada linha da página, com lotes, locais e catálogo lidos
    # numa consulta cada.
    def present(rows, today:, cutoff:)
      return [] if rows.empty?

      keys = rows.map { |row| [ row["location_id"], row["catalog_item_id"] ] }
      lot_rows = lot_rows(keys).group_by { |row| [ row["location_id"], row["catalog_item_id"] ] }
      stock_lots = StockLot.where(id: lot_rows.values.flatten.map { |row| row["lot_id"] }).index_by(&:id)
      locations = StockLocation.includes(:health_unit).where(id: keys.map(&:first)).index_by(&:id)
      catalog = Json.catalog_for(keys.map(&:last))

      rows.map do |row|
        key = [ row["location_id"], row["catalog_item_id"] ]
        lots = lots_of(lot_rows.fetch(key, []), stock_lots: stock_lots, catalog: catalog, today: today, cutoff: cutoff)
        item = catalog.fetch(row["catalog_item_id"])
        minimum = row["minimum"]&.to_d
        { location: Json.location(locations.fetch(row["location_id"])),
          item: Json.item(item, dispensing_unit: lots.first&.dig(:lot, :item, :dispensing_unit) || DispensingUnit.for(item)),
          lots: lots, balance: Quantity.dump(row["balance"].to_d), minimum: minimum && Quantity.dump(minimum),
          below_minimum: flag(row["below_minimum"]), expiring_soon: flag(row["expiring_soon"]) }
      end
    end
    private_class_method :present

    # lots[] da posição em ordem FEFO (validade, número, id).
    def lots_of(rows, stock_lots:, catalog:, today:, cutoff:)
      rows.map { |row| [ stock_lots.fetch(row["lot_id"]), row ] }
          .sort_by { |lot, _row| [ lot.expires_on, lot.lot_number, lot.id ] }
          .map do |lot, row|
        expired = lot.expires_on < today
        { lot: Json.lot(lot, catalog: catalog), balance: Quantity.dump(row["balance"].to_d), in_transit: Quantity.dump(row["in_transit"].to_d),
          expiring_soon: !expired && lot.expires_on <= cutoff, expired: expired }
      end
    end
    private_class_method :lots_of

    def flag(value) = ActiveModel::Type::Boolean.new.cast(value) ? true : false
    private_class_method :flag
  end
end
