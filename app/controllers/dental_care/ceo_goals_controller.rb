# GET /dental/ceo_goals?health_unit_id=&month=AAAA-MM (contrato §10, §16
# O15/O24): metas do CEO no mês, faltas e histórico dos 12 meses fechados.
# Só contagens, sem trilha; leitores dos painéis (municipal_admin, analyst).
module DentalCare
  class CeoGoalsController < BaseController
    MONTH = /\A\d{4}-(0[1-9]|1[0-2])\z/

    before_action { forbid unless panel_reader? }

    def show
      return render_refusal("health_unit_id") unless uuid?(params[:health_unit_id])

      month = parse_month(params[:month])
      return render_refusal("month") unless month

      unit = HealthUnit.includes(:ceo_profile).find_by(id: params[:health_unit_id])
      return not_found unless unit
      return render_error("unit_not_ceo") unless unit.kind == "ceo" && unit.ceo_profile

      render json: CeoGoals.call(unit: unit, month: month)
    end

    private

    # AAAA-MM até o mês corrente (fuso da cidade); senão nil.
    def parse_month(raw)
      return nil unless raw.is_a?(String) && raw.match?(MONTH)

      month = Date.new(*raw.split("-").map(&:to_i), 1)
      month <= Time.zone.today.beginning_of_month ? month : nil
    end
  end
end
