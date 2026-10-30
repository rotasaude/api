# GET /pharmacy/lots/:id/movements (contrato §4 e H12): o extrato de um lote
# num local, mais novos primeiro, com cursor opaco. Sem trilha. O motivo (texto
# livre) vai só no corpo; o da devolução só para o farmacêutico ou o auxiliar
# do local (os demais leem `reason: null`); a dispensação aparece só com o id.
#
# `location_id` obrigatório e legível pelo usuário (qualquer papel nele; o
# almoxarife do central lê todos): inexistente → 422, sem papel → 403. Lote da
# URL inexistente ou sem nenhuma presença no local (movimento ou transferência
# em trânsito para ele) → 404.
module Pharmacy
  class StatementsController < BaseController
    include LocationReading

    def index
      return unless query_only!(:location_id, :before, :limit)

      location = required_location or return
      lot = uuid?(params[:id]) ? StockLot.find_by(id: params[:id]) : nil
      return not_found unless lot && present_at?(location, lot)

      limit = page_limit or return
      cursor = params.key?(:before) ? Cursor.decode(params[:before]) : nil
      return render_refusal("before", "invalid_cursor") if params.key?(:before) && !statement_cursor?(cursor)

      reasons = Access.allowed?(user: Current.user, location: location, roles: Catalog::DISPENSER_ROLES)
      render json: Statement.call(location: location, lot: lot, before: cursor, limit: limit, reasons: reasons)
    end

    private

    # [recorded_at, created_at, id]: duas datas ISO e o uuid do movimento.
    def statement_cursor?(cursor)
      return false unless cursor && cursor.size == 3 && uuid?(cursor.last)

      cursor.first(2).each { |text| Time.iso8601(text) }
      true
    rescue ArgumentError
      false
    end

    # O lote é conhecido no local: tem movimento nele ou chega em trânsito.
    def present_at?(location, lot)
      StockMovement.where(stock_location_id: location.id, stock_lot_id: lot.id).exists? ||
        StockTransferItem.joins(:stock_transfer).exists?(stock_lot_id: lot.id, stock_transfers: { status: "sent", to_location_id: location.id })
    end
  end
end
