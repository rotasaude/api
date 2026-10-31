# GET /dental/indicators?team_id=&period=AAAA-MM (spec decisão 13; contrato
# §16 O15/O24): B1 e B2 da eSB nos 12 meses que terminam no mês. Só
# contagens, sem trilha; leitores dos painéis (municipal_admin, analyst).
module DentalCare
  class IndicatorsController < BaseController
    PERIOD = /\A\d{4}-(0[1-9]|1[0-2])\z/

    before_action { forbid unless panel_reader? }

    def show
      return render_refusal("team_id") unless uuid?(params[:team_id])

      # eSB inativa continua consultável (histórico); /dental/teams lista só as ativas.
      team = HealthTeam.includes(:associated_team).find_by(id: params[:team_id])
      return not_found unless team
      return render_refusal("team_id") unless team.kind == Catalog::ORAL_HEALTH_TEAM_KIND
      return render_refusal("period") unless valid_period?(params[:period])

      render json: Indicators.call(team: team, period: params[:period])
    end

    private

    # AAAA-MM até o mês corrente (fuso da cidade).
    def valid_period?(raw)
      raw.is_a?(String) && raw.match?(PERIOD) && raw <= Time.zone.today.strftime("%Y-%m")
    end
  end
end
