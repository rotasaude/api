# GET /pharmacy/openings?location_id=&before=&limit= (módulo 27b, Task 13; Q13, Q19):
# as aberturas de estoque do local, a mais nova primeiro, com os lotes e o que
# falta para o envio à BNAFAR. Exige só o estoque do domínio do local
# (`require_stock_feature!` + `stock_feature_for!`), nunca o `bnafar`. Quem lê:
# papel no local ou o almoxarife do central / da rede de frio (como a posição).
# Inclui as revertidas (`reverted: true`). `from_import` fica `false` até a
# Task 14 ligar a planilha. Só `recorded_by.name`: nenhum outro dado de pessoa.
module Pharmacy
  class OpeningsController < BaseController
    include LocationReading

    NO_NAME = "—".freeze
    PRELOAD = [ { recorded_by_user: :professional }, { movements: { stock_lot: :vector_product } } ].freeze

    skip_before_action :require_pharmacy!
    before_action :require_stock_feature!

    def index
      return unless query_only!(:location_id, :before, :limit)

      location = required_location or return
      return unless stock_feature_for!(location)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !valid_cursor?(cursor)

      scope = StockEntry.where(stock_location_id: location.id, kind: "opening").where(id: StockOpening.where(stock_location_id: location.id).select(:stock_entry_id))
      scope = scope.where("(stock_entries.created_at, stock_entries.id) < (?, ?)", Time.iso8601(cursor.first), cursor.last) if cursor
      rows = scope.includes(*PRELOAD).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
      page = rows.first(limit)
      render json: { items: present(page, location),
                     next_before: rows.size > limit ? Cursor.encode([ page.last.created_at.utc.iso8601(6), page.last.id ]) : nil }
    end

    private

    def present(entries, location)
      openings = StockOpening.where(stock_entry_id: entries.map(&:id)).group_by(&:stock_entry_id)
      lots = entries.flat_map { |entry| opening_movements(entry).map(&:stock_lot) }
      catalog = Json.catalog_for(lots.map(&:catalog_item_id))
      entries.map do |entry|
        marks = openings.fetch(entry.id, [])
        { stock_entry_id: entry.id, created_at: entry.created_at.iso8601,
          recorded_by: { name: entry.recorded_by_user.professional&.professional_name || NO_NAME },
          from_import: false, reverted: marks.any? && marks.all?(&:reverted_at),
          lots: opening_movements(entry).map { |movement| lot_row(movement, catalog) } }
      end
    end

    def opening_movements(entry) = entry.movements.select { |movement| movement.kind == "opening" }.sort_by { |movement| [ movement.stock_lot.lot_number, movement.stock_lot_id ] }

    def lot_row(movement, catalog)
      body = Json.lot(movement.stock_lot, catalog: catalog, bnafar: true)
      { stock_lot_id: movement.stock_lot_id, item_label: body.dig(:item, :name), lot_number: body[:lot_number], expires_on: body[:expires_on],
        quantity: Quantity.dump(movement.quantity), bnafar: { missing: body.dig(:bnafar, :missing) } }
    end
  end
end
