# Posição de estoque de imunobiológicos por (local, imunobiológico) (ADR 0047,
# Desvio 3; §15 V4/V18, D5 do dashboard): a conta de Pharmacy::Positions com a
# chave `immunobiological_code` no lugar de `catalog_item_id`, numa CTE própria.
# Saldo = SUM(stock_movements.quantity); "em trânsito" = soma de `quantity_sent`
# das transferências `sent` com destino no local. Sem mínimos por enquanto:
# `minimum: null` e `below_minimum: false`.
#
# A forma é a `<position>` do 27a: `{ location, item, lots, balance, minimum,
# below_minimum, expiring_soon }`, com o <item> de imunobiológico
# (Pharmacy::Json.immunobiological_item). Cada lote (`LotBalance`) ganha
# `blocked`: bloqueio aberto (excursão de temperatura) do lote NAQUELE local.
# Ordem estável por (local, código) com cursor opaco `[location_id, code]`.
# Sem dado de paciente e sem trilha.
module Vaccination
  module StockPositions
    module_function

    # `before` é o cursor JÁ decodificado e validado ([location_id, code]);
    # `codes` (opcional) restringe os imunobiológicos.
    # -> { positions: [<position>], next_before: String | nil }
    def call(location_ids:, limit:, today:, settings:, before: nil, codes: nil, expiring: false)
      cutoff = today + settings.expiry_alert_days
      tail = +"SELECT * FROM positions WHERE TRUE"
      binds = { fetch: limit + 1 }
      tail << " AND expiring_soon" if expiring
      if codes
        tail << " AND code IN (:codes)"
        binds[:codes] = codes
      end
      if before
        tail << " AND (location_id, code) > (CAST(:cursor_location AS uuid), CAST(:cursor_code AS varchar))"
        binds.merge!(cursor_location: before.first, cursor_code: before.last)
      end
      tail << " ORDER BY location_id, code LIMIT :fetch"
      rows = query(tail, location_ids: location_ids, cutoff: cutoff, binds: binds)

      page = rows.first(limit)
      { positions: present(page, today: today, cutoff: cutoff),
        next_before: rows.size > limit ? Pharmacy::Cursor.encode([ page.last["location_id"], page.last["code"] ]) : nil }
    end

    # Códigos do catálogo da sala cujo nome casa TODOS os termos de `q` (sem
    # acento, maiúsculos, até 6). -> Array<String>
    def codes_matching(q)
      tokens = fold(q).split.first(6)
      return [] if tokens.empty?

      Immunobiologicals.all.select { |product| tokens.all? { |token| fold(product.name).include?(token) } }.map(&:code)
    end

    def fold(text) = I18n.transliterate(text.to_s).upcase

    # CTEs `lots` (local, código, lote, saldo, trânsito) e `positions`.
    def query(tail, location_ids:, cutoff:, binds: {})
      sql = <<~SQL
        WITH balances AS (
          SELECT m.stock_location_id AS location_id, m.immunobiological_code AS code, m.stock_lot_id AS lot_id,
                 SUM(m.quantity) AS balance, 0::numeric AS in_transit
          FROM stock_movements m
          WHERE m.stock_location_id IN (:location_ids) AND m.immunobiological_code IS NOT NULL
          GROUP BY m.stock_location_id, m.immunobiological_code, m.stock_lot_id
        ), transit AS (
          SELECT t.to_location_id AS location_id, l.immunobiological_code AS code, i.stock_lot_id AS lot_id,
                 0::numeric AS balance, SUM(i.quantity_sent) AS in_transit
          FROM stock_transfer_items i
          JOIN stock_transfers t ON t.id = i.stock_transfer_id
          JOIN stock_lots l ON l.id = i.stock_lot_id
          WHERE t.status = 'sent' AND t.to_location_id IN (:location_ids) AND l.immunobiological_code IS NOT NULL
          GROUP BY t.to_location_id, l.immunobiological_code, i.stock_lot_id
        ), lots AS (
          SELECT location_id, code, lot_id, SUM(balance) AS balance, SUM(in_transit) AS in_transit
          FROM (SELECT * FROM balances UNION ALL SELECT * FROM transit) joined
          GROUP BY location_id, code, lot_id
        ), positions AS (
          SELECT l.location_id, l.code, COALESCE(SUM(l.balance), 0) AS balance,
                 COALESCE(BOOL_OR(l.balance > 0 AND sl.expires_on <= :cutoff), FALSE) AS expiring_soon
          FROM lots l
          JOIN stock_lots sl ON sl.id = l.lot_id
          GROUP BY l.location_id, l.code
        )
        #{tail}
      SQL
      values = { location_ids: Array(location_ids), cutoff: cutoff }.merge(binds)
      StockMovement.connection.select_all(StockMovement.sanitize_sql_array([ sql, values ])).to_a
    end
    private_class_method :query

    def present(rows, today:, cutoff:)
      return [] if rows.empty?

      keys = rows.map { |row| [ row["location_id"], row["code"] ] }
      lot_rows = query("SELECT * FROM lots", location_ids: keys.map(&:first).uniq, cutoff: cutoff)
                 .group_by { |row| [ row["location_id"], row["code"] ] }.slice(*keys)
      lot_ids = lot_rows.values.flatten.map { |row| row["lot_id"] }
      stock_lots = StockLot.where(id: lot_ids).index_by(&:id)
      blocked = StockLotBlock.open_blocks.where(stock_location_id: keys.map(&:first), stock_lot_id: lot_ids)
                             .pluck(:stock_location_id, :stock_lot_id).to_set
      locations = StockLocation.includes(:health_unit).where(id: keys.map(&:first)).index_by(&:id)

      rows.map do |row|
        key = [ row["location_id"], row["code"] ]
        { location: Pharmacy::Json.location(locations.fetch(row["location_id"])),
          item: Pharmacy::Json.immunobiological_item(row["code"]),
          lots: lots_of(lot_rows.fetch(key, []), location_id: row["location_id"], stock_lots: stock_lots, blocked: blocked, today: today, cutoff: cutoff),
          balance: Pharmacy::Quantity.dump(row["balance"].to_d), minimum: nil, below_minimum: false,
          expiring_soon: ActiveModel::Type::Boolean.new.cast(row["expiring_soon"]) ? true : false }
      end
    end
    private_class_method :present

    # lots[] em ordem FEFO (validade, número, id), cada um com `blocked`.
    def lots_of(rows, location_id:, stock_lots:, blocked:, today:, cutoff:)
      rows.map { |row| [ stock_lots.fetch(row["lot_id"]), row ] }
          .sort_by { |lot, _row| [ lot.expires_on, lot.lot_number, lot.id ] }
          .map do |lot, row|
        expired = lot.expires_on < today
        { lot: Pharmacy::Json.lot(lot, catalog: {}), balance: Pharmacy::Quantity.dump(row["balance"].to_d),
          in_transit: Pharmacy::Quantity.dump(row["in_transit"].to_d), expiring_soon: !expired && lot.expires_on <= cutoff, expired: expired,
          blocked: blocked.include?([ location_id, lot.id ]) }
      end
    end
    private_class_method :lots_of
  end
end
