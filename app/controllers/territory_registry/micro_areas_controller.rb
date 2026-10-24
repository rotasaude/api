# /territory/admin/micro_areas (contrato §3; F-24.1): municipal_admin; escrita
# com step-up; corpo só JSON (team_id, código e nome na query não valem).
module TerritoryRegistry
  class MicroAreasController < BaseController
    before_action { forbid unless Access.admin?(Current.user) }
    before_action :require_step_up!, only: %i[create update]

    def index
      team = uuid?(params[:team_id]) && HealthTeam.find_by(id: params[:team_id])
      return not_found unless team

      areas = MicroArea.where(team: team).includes(:team, :acs_professional).order(:code)
      render json: { micro_areas: areas.map { |area| Json.micro_area(area) } }
    end

    def create
      result = SaveMicroArea.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.micro_area(result.payload[:micro_area]), status: :created
    end

    def update
      area = uuid?(params[:id]) && MicroArea.find_by(id: params[:id])
      return not_found unless area

      result = SaveMicroArea.call(params: body, by: Current.user, micro_area: area)
      return render_failure(result) if result.failure?

      render json: Json.micro_area(result.payload[:micro_area])
    end
  end
end
