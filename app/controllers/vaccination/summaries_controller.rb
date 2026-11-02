# Resumo mensal de imunobiológicos (contrato §7; §15 V14 = D8 do dashboard):
#   GET /vaccination/rooms/:room_id/monthly_summary?month=YYYY-MM          (equipe da sala, qualquer papel)
#   GET /vaccination/cold_chain_central/monthly_summary?month=YYYY-MM      (stock_keeper da rede de frio)
# Só contagens: sem trilha e sem dado de paciente. Mês ausente ou inválido →
# 422 `month`; escopo alheio → 403; sala inexistente → 404.
module Vaccination
  class SummariesController < BaseController
    def room
      room = member_room or return
      return unless query_only!(:month)

      summarize(room.stock_location)
    end

    def cold_chain
      return unless query_only!(:month)

      location = StockLocation.find_by(kind: "cold_chain_central", active: true)
      return not_found unless location
      return forbid unless Access.cold_chain_roles(user: Current.user, location: location).include?("stock_keeper")

      summarize(location)
    end

    private

    def summarize(location)
      month = params[:month]
      return render_refusal("month") unless month.is_a?(String) && MonthlySummary.valid_month?(month)

      render json: MonthlySummary.call(location: location, month: month)
    end
  end
end
