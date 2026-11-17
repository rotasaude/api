# /vector_control/settings (módulo 35a, ADR 0054; contrato §4, §12; Q8): o
# local de estoque de onde o boletim baixa, só a coordenação (403
# missing_role). GET e PUT devolvem o VectorSettings `{ stock_location: { id,
# name } | null, options: [{ id, name }] }` (opções = os locais vector_control
# ativos). Corpo do PUT `{ stock_location_id }` (nulo = sem baixa).
module VectorControl
  class SettingsController < BaseController
    before_action(only: :update) { query_only! }
    before_action :coordinator!

    def show
      return unless query_only!

      render json: Json.settings(VectorControlSetting.current)
    end

    def update
      unknown = (body.keys - %w[stock_location_id]).first
      return render_refusal("invalid_request", path: unknown) if unknown
      return render_refusal("invalid_request", path: "stock_location_id") unless body.key?("stock_location_id")

      result = SaveSettings.call(stock_location_id: body_param("stock_location_id"), by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.settings(result.payload.fetch(:setting))
    end
  end
end
