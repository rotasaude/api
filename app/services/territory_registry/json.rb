# Formas JSON do cadastro territorial (contrato §2; §14 L2). Só o que a rota
# mostra: nada de CNS em claro (o candidato a ACS leva só has_cns).
module TerritoryRegistry
  module Json
    module_function

    def micro_area(area)
      acs = area.acs_professional
      { id: area.id, team: team_ref(area.team), code: area.code, name: area.name,
        acs: acs && { professional_id: acs.id, name: acs.professional_name }, active: area.active }
    end

    def team_ref(team) = { id: team.id, ine: team.ine, name: team.name }

    # candidates: os HealthTeamMember ACS ativos da equipe (com o profissional).
    def admin_team(team, candidates)
      team_ref(team).merge(kind: team.kind, unit: { id: team.health_unit.id, name: team.health_unit.name },
                           acs_candidates: candidates.map { |member| acs_candidate(member.professional) })
    end

    def acs_candidate(professional)
      { professional_id: professional.id, name: professional.professional_name,
        has_cns: Professionals::Cns.valid?(professional.cns) }
    end
  end
end
