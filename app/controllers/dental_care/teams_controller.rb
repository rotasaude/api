# GET /dental/teams (contrato §16 O11/O23; Ruling 11): as eSB (71) ativas, para
# o seletor do B1/B2. Leitores dos painéis (municipal_admin, analyst).
module DentalCare
  class TeamsController < BaseController
    before_action { forbid unless panel_reader? }

    def index
      limit = page_limit or return

      teams = HealthTeam.includes(:health_unit).where(kind: Catalog::ORAL_HEALTH_TEAM_KIND, active: true).order(:name, :id).limit(limit)
      render json: { teams: teams.map do |team|
        { id: team.id, name: team.name, ine: team.ine, health_unit: { id: team.health_unit.id, name: team.health_unit.name } }
      end }
    end
  end
end
