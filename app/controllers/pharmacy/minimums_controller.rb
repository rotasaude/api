# GET/PUT /pharmacy/locations/:id/minimums (contrato §3 e H12): o estoque
# mínimo do local. `stock_keeper` do local ou o almoxarife do central (que lê e
# grava os de qualquer local). Mínimo não é dado sensível: o PUT não pede
# step-up. Corpo e resposta: `{ minimums: [ { catalog_item_id, minimum, item } ] }`
# (`item` só na saída; o que vier na entrada é ignorado).
module Pharmacy
  class MinimumsController < BaseController
    before_action :load_location
    before_action :require_keeper

    def show = render(json: { minimums: minimums_json })

    def update
      return render_error(:location_inactive, :conflict) unless @location.active

      result = SaveMinimums.call(location: @location, rows: body_param("minimums"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: { minimums: minimums_json }
    end

    private

    def load_location
      @location = uuid?(params[:id]) && StockLocation.find_by(id: params[:id])
      not_found unless @location
    end

    def require_keeper
      return if Access.central_keeper?(Current.user) || Access.allowed?(user: Current.user, location: @location, roles: "stock_keeper")

      forbid
    end

    # Só os maiores que zero (zero é "sem mínimo": a linha fica, o alerta não).
    def minimums_json
      rows = StockMinimum.where(stock_location_id: @location.id).where("minimum > 0").to_a
      catalog = Json.catalog_for(rows.map(&:catalog_item_id))
      rows.map { |row| { catalog_item_id: row.catalog_item_id, minimum: Quantity.dump(row.minimum), item: Json.catalog_item(catalog.fetch(row.catalog_item_id)) } }
          .sort_by { |row| [ row.dig(:item, :name).to_s, row[:catalog_item_id] ] }
    end
  end
end
