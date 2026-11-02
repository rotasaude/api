# Resumo mensal de imunobiológicos por local, sala ou rede de frio (ADR 0047;
# §15 V14 = D8 do dashboard; SIES e SIPNI). Só contagens, em doses: nenhuma
# trilha, nenhum dado de paciente (a dose entra só como número).
#
#   { month: "YYYY-MM", location: <location do 27a>,
#     rows: [ { immunobiological: { code, name }, lot: { id, number, expires_on },
#               opening_balance, received, transferred_in, transferred_out,
#               vials_opened, doses_applied, technical_loss,
#               physical_loss: { "<loss_code>" => n }, closing_balance,
#               vial_doses, unit_doses, adjustment } ] }
#
# O mês é o da cidade (fuso do Rails). Saldo = soma dos movimentos do razão do
# 27a: perda `pending` (aguardando aprovação) não tem movimento e por isso não
# conta, nem no saldo nem na perda física. A conta fecha por linha:
#
#   closing = opening + received + transferred_in − transferred_out
#             − vial_doses − unit_doses + adjustment − Σ physical_loss
#
# `vial_doses` = doses que saíram do estoque ao abrir frascos (vials_opened ×
# doses por frasco) e `unit_doses` = doses de unidose (líquido das devoluções
# por cancelamento): as duas saem do estoque na aplicação, ao contrário de
# `technical_loss` (sobra do frasco fechado no mês, já fora do estoque desde a
# abertura) e `doses_applied` (imunizações ativas, não transcritas, da sala no
# mês, por lote). `adjustment` é a contagem de inventário (com sinal).
module Vaccination
  module MonthlySummary
    MONTH = /\A(\d{4})-(0[1-9]|1[0-2])\z/
    ENTRY_KINDS = %w[opening receipt donation].freeze
    UNSPECIFIED_LOSS = "unspecified".freeze
    TRANSFER_LOSS = "transfer_difference".freeze

    module_function

    # Mês "YYYY-MM" válido (ano 2000..2100)? -> Boolean
    def valid_month?(month)
      match = MONTH.match(month.to_s)
      match.present? && (2000..2100).cover?(match[1].to_i)
    end

    # -> { month:, location:, rows: [ … ] }; mês inválido → ArgumentError.
    def call(location:, month:)
      raise ArgumentError, "invalid month" unless valid_month?(month)

      from = Time.zone.parse("#{month}-01").beginning_of_month
      to = from + 1.month
      lots = movement_rows(location, from, to)
      losses = physical_losses(location, from, to)
      applied = applied_counts(location, from, to)
      opened = opened_counts(location, from, to)
      technical = technical_losses(location, from, to)

      ids = (lots.keys | losses.keys | applied.keys | opened.keys | technical.keys)
      stock_lots = StockLot.where(id: ids).index_by(&:id)
      rows = ids.map { |id| row(stock_lots.fetch(id), lots[id], losses[id] || {}, applied[id], opened[id], technical[id]) }
      { month: month, location: Pharmacy::Json.location(location),
        rows: rows.reject { |entry| empty?(entry) }.sort_by { |entry| [ entry[:immunobiological][:code], entry[:lot][:expires_on], entry[:lot][:number], entry[:lot][:id] ] } }
    end

    def row(lot, sums, loss, applied, opened, technical)
      sums ||= {}
      product = Immunobiologicals.find(lot.immunobiological_code)
      { immunobiological: { code: lot.immunobiological_code, name: product&.name },
        lot: { id: lot.id, number: lot.lot_number, expires_on: lot.expires_on.iso8601 },
        opening_balance: sums["opening"].to_i, received: sums["received"].to_i,
        transferred_in: sums["transferred_in"].to_i, transferred_out: sums["transferred_out"].to_i,
        vials_opened: opened.to_i, doses_applied: applied.to_i, technical_loss: technical.to_i,
        physical_loss: loss.sort.to_h, closing_balance: sums["closing"].to_i,
        vial_doses: sums["vial_doses"].to_i, unit_doses: sums["unit_doses"].to_i, adjustment: sums["adjustment"].to_i }
    end
    private_class_method :row

    def empty?(entry)
      entry.except(:immunobiological, :lot, :physical_loss).values.all?(&:zero?) && entry[:physical_loss].empty?
    end
    private_class_method :empty?

    # { lot_id => { "opening" =>, "received" =>, … } }, doses inteiras.
    def movement_rows(location, from, to)
      sql = <<~SQL
        SELECT m.stock_lot_id AS lot_id,
               COALESCE(SUM(m.quantity) FILTER (WHERE m.recorded_at < :from), 0) AS opening,
               COALESCE(SUM(m.quantity) FILTER (WHERE m.recorded_at >= :from AND m.kind IN (:entries)), 0) AS received,
               COALESCE(SUM(m.quantity) FILTER (WHERE m.recorded_at >= :from AND m.kind = 'transfer_in'), 0) AS transferred_in,
               COALESCE(-SUM(m.quantity) FILTER (WHERE m.recorded_at >= :from AND m.kind = 'transfer_out'), 0) AS transferred_out,
               COALESCE(-SUM(m.quantity) FILTER (WHERE m.recorded_at >= :from AND m.kind = 'vial_opening'), 0) AS vial_doses,
               COALESCE(-SUM(m.quantity) FILTER (WHERE m.recorded_at >= :from AND m.kind IN ('immunization', 'immunization_reversal')), 0) AS unit_doses,
               COALESCE(SUM(m.quantity) FILTER (WHERE m.recorded_at >= :from AND m.kind = 'adjustment'), 0) AS adjustment,
               COALESCE(SUM(m.quantity), 0) AS closing
        FROM stock_movements m
        WHERE m.stock_location_id = :location AND m.immunobiological_code IS NOT NULL AND m.recorded_at < :to
        GROUP BY m.stock_lot_id
      SQL
      select(sql, location: location.id, from: from, to: to, entries: ENTRY_KINDS).to_h do |record|
        [ record["lot_id"], record.except("lot_id").transform_values { |value| value.to_d.to_i } ]
      end
    end
    private_class_method :movement_rows

    # { lot_id => { loss_code => doses } }: só perda/vencimento com movimento
    # (a `pending` não tem), no mês do movimento.
    def physical_losses(location, from, to)
      sql = <<~SQL
        SELECT m.stock_lot_id AS lot_id,
               COALESCE(a.loss_code, CASE WHEN m.stock_transfer_id IS NOT NULL THEN :transfer ELSE :unspecified END) AS code,
               -SUM(m.quantity) AS doses
        FROM stock_movements m
        LEFT JOIN stock_adjustments a ON a.id = m.stock_adjustment_id
        WHERE m.stock_location_id = :location AND m.immunobiological_code IS NOT NULL
          AND m.kind IN ('loss', 'expiry') AND m.recorded_at >= :from AND m.recorded_at < :to
        GROUP BY m.stock_lot_id, 2
      SQL
      select(sql, location: location.id, from: from, to: to, transfer: TRANSFER_LOSS, unspecified: UNSPECIFIED_LOSS).each_with_object({}) do |record, memo|
        (memo[record["lot_id"]] ||= {})[record["code"]] = record["doses"].to_d.to_i
      end
    end
    private_class_method :physical_losses

    # Doses ativas, não transcritas, da sala (a rede de frio não aplica).
    def applied_counts(location, from, to)
      room = VaccineRoom.find_by(stock_location_id: location.id) or return {}
      Immunization.active.where(vaccine_room_id: room.id, transcription: false, applied_at: from...to).where.not(stock_lot_id: nil).group(:stock_lot_id).count
    end
    private_class_method :applied_counts

    def opened_counts(location, from, to)
      room = VaccineRoom.find_by(stock_location_id: location.id) or return {}
      VialOpening.where(vaccine_room_id: room.id, opened_at: from...to).group(:stock_lot_id).count
    end
    private_class_method :opened_counts

    # Sobra dos frascos FECHADOS no mês (descarte ou vencimento).
    def technical_losses(location, from, to)
      room = VaccineRoom.find_by(stock_location_id: location.id) or return {}
      VialOpening.where(vaccine_room_id: room.id, closed_at: from...to).group(:stock_lot_id).sum(:technical_loss_doses)
    end
    private_class_method :technical_losses

    def select(sql, **binds)
      StockMovement.connection.select_all(StockMovement.sanitize_sql_array([ sql, binds ])).to_a
    end
    private_class_method :select
  end
end
