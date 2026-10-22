# Prévia (contrato §6): municipal_admin e analyst; agregado sem nome; sem
# trilha (não há leitura nominal).
module CareLines
  class PreviewsController < BaseController
    before_action { forbid unless Access.preview?(Current.user) }

    def show
      return render_error(:invalid_indicator) unless Preview::INDICATORS.include?(params[:indicator])

      team = uuid?(params[:team_id]) && HealthTeam.find_by(id: params[:team_id])
      return not_found unless team

      result = Preview.call(team: team, indicator: params[:indicator], today: Time.zone.today)
      return render_error(:catalog_not_loaded, :service_unavailable) unless result

      render json: result
    end
  end
end
