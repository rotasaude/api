# GET /territory/teams (contrato §14 L2): as equipes 70/76 ativas do vínculo
# do profissional, com as microáreas ATIVAS e can_register — a mesma regra
# da gravação (Access.registrar?, nas fichas individual e domiciliar). Sem
# trilha (nenhum dado de cidadão); quem não tem vínculo recebe lista vazia.
module TerritoryRegistry
  class TeamsController < BaseController
    def index
      professional = Current.user.professional
      team_ids = professional ? HealthTeamMember.active.where(professional: professional).pluck(:health_team_id) : []
      teams = HealthTeam.where(id: team_ids, active: true, kind: Catalog::TEAM_KINDS).includes(:health_unit).order(:name, :ine).to_a
      areas = MicroArea.where(team_id: teams.map(&:id), active: true).includes(:team, :acs_professional).order(:code).group_by(&:team_id)
      render json: { teams: teams.map { |team|
        rows = areas[team.id] || []
        allowed = rows.select { |area| registrar?(team, area) }.map(&:id)
        Json.professional_team(team, rows, can_register: allowed)
      } }
    end

    private

    def registrar?(team, area)
      %i[individual household].all? { |ficha| Access.registrar?(Current.user, team, ficha: ficha, micro_area: area) == :ok }
    end
  end
end
