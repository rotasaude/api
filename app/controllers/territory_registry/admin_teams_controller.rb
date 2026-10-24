# GET /territory/admin/teams (contrato §14 L2): municipal_admin; equipes
# ativas 70/76 com os candidatos a ACS — membros ativos da equipe com CBO
# 515105, a mesma regra do SaveMicroArea — e has_cns. Sem trilha (nenhum dado
# de cidadão), sem paginação (equipes da cidade).
module TerritoryRegistry
  class AdminTeamsController < BaseController
    before_action { forbid unless Access.admin?(Current.user) }

    def index
      teams = HealthTeam.where(active: true, kind: Catalog::TEAM_KINDS).includes(:health_unit).order(:name, :ine).to_a
      candidates = HealthTeamMember.active.where(health_team_id: teams.map(&:id), cbo_code: Catalog::ACS_CBO)
                                   .includes(:professional).group_by(&:health_team_id)
      render json: { teams: teams.map { |team|
        members = (candidates[team.id] || []).sort_by { |m| [ m.professional.professional_name, m.professional_id ] }
        Json.admin_team(team, members)
      } }
    end
  end
end
