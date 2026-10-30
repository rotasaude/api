# /dental/admin/oral_health_teams (Desvio 13, D7; contrato §16 O11): as eSB
# ativas com a eSF/eAP associada e as candidatas da unidade; o admin associa
# quando o CNES não decide. Só o municipal_admin; escrita com step-up.
module DentalCare
  module Admin
    class OralHealthTeamsController < BaseController
      before_action { forbid unless admin? }
      before_action :require_step_up!, only: :update

      def index
        limit = page_limit or return
        teams = oral_health_teams.order(:name, :ine).limit(limit).to_a
        candidates = HealthTeam.where(health_unit_id: teams.map(&:health_unit_id), active: true, kind: HealthTeam::PRIMARY_CARE_KINDS)
                               .order(:name, :ine).group_by(&:health_unit_id)
        render json: { teams: teams.map { |team| team_json(team, candidates.fetch(team.health_unit_id, [])) } }
      end

      def update
        team = uuid?(params[:id]) ? oral_health_teams.find_by(id: params[:id]) : nil
        return not_found unless team

        result = AssociateTeam.call(team: team, params: body, by: Current.user)
        return render_failure(result) if result.failure?

        render json: team_json(team.reload, AssociateTeam.candidates(team).order(:name, :ine).to_a)
      end

      private

      def oral_health_teams
        HealthTeam.where(kind: Catalog::ORAL_HEALTH_TEAM_KIND, active: true).includes(:health_unit, :associated_team)
      end

      def team_json(team, candidates)
        { id: team.id, ine: team.ine, name: team.name, health_unit: { id: team.health_unit.id, name: team.health_unit.name },
          associated_team: team.associated_team && ref(team.associated_team), candidates: candidates.map { |c| ref(c) } }
      end

      def ref(team) = { id: team.id, ine: team.ine, name: team.name }
    end
  end
end
