# Painel da vacinação (ADR 0047; §15 V14 = D13): municipal_admin e analyst.
#   GET /vaccination/dashboard?month=YYYY-MM&health_unit_id=
# Só contagens, sem trilha. Sem `month`, o mês corrente. `month` inválido ou
# `health_unit_id` malformado → 422 (path); unidade inexistente → 404. O
# interruptor da RNDS é lido aqui, fora de transação.
module Vaccination
  class DashboardController < BaseController
    before_action { forbid unless admin? || Current.user.has_role?("analyst") }

    def show
      return unless query_only!(:month, :health_unit_id)

      month = params.key?(:month) ? params[:month] : Time.zone.today.strftime("%Y-%m")
      return render_refusal("month") unless month.is_a?(String) && MonthlySummary.valid_month?(month)

      unit = nil
      if params.key?(:health_unit_id)
        return render_refusal("health_unit_id") unless uuid?(params[:health_unit_id])

        unit = HealthUnit.find_by(id: params[:health_unit_id])
        return not_found unless unit
      end

      render json: Dashboard.call(month: month, unit: unit, rnds_enabled: Rnds::Gate.enabled?(Current.city))
    end
  end
end
