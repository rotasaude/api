# GET /home_visits/context (contrato §6; Q13, Q14; pre-flight 4.2): as equipes
# ativas 70/76 do vínculo de quem lê em que ele tem papel na visita (Tabela 7,
# enfermeiro, médico), com as capacidades, as microáreas ATIVAS do escopo e os
# domínios da ficha. Sem trilha (nenhum dado de cidadão); sem vínculo → lista
# vazia. O api continua recusando o que as capacidades negam.
module HomeVisits
  class ContextController < BaseController
    def show
      return unless query_only!

      today = Time.zone.today
      render json: { today: today.iso8601, min_date: Rules.min_date(today).iso8601, teams: teams.map { |team, member| team_json(team, member) },
                     domains: Json.domains }
    end

    private

    # [[equipe, vínculo]] em que o papel existe (ordem: nome, INE).
    def teams
      professional = Current.user.professional
      return [] unless professional

      team_ids = HealthTeamMember.active.where(professional: professional).pluck(:health_team_id)
      HealthTeam.where(id: team_ids, active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS).order(:name, :ine).filter_map do |team|
        member = Access.member(Current.user, team)
        [ team, member ] if Access.role(member)
      end
    end

    def team_json(team, member)
      role = Access.role(member)
      scope = Access.scope(Current.user, team)
      areas = MicroArea.where(id: scope[:micro_area_ids], active: true).order(:code)
      field = %i[acs field].include?(role)
      { id: team.id, ine: team.ine, name: team.name, cbo: member.cbo_code, can_register: field,
        can_assign: Access.assigner?(Current.user, team), can_register_device: field, reads_whole_team: role == :reader,
        out_of_area_allowed: role == :acs,
        micro_areas: areas.map { |area| Json.micro_area(area).merge(scope: scope[:kind]) },
        professionals: role == :reader ? field_professionals(team) : [] }
    end

    # Os da Tabela 7 com vínculo ativo na equipe (Q14), por nome.
    def field_professionals(team)
      HealthTeamMember.active.includes(:professional).where(health_team: team, cbo_code: Catalog::HOME_VISIT_CBOS.to_a)
                      .sort_by { |member| [ member.professional.professional_name, member.professional_id ] }
                      .map { |member| Json.professional(member.professional, member.cbo_code) }
    end
  end
end
