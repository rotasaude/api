# Formas JSON do cadastro territorial (contrato §2; §14 L2, L6, L7). Só o que
# a rota mostra: nada de CNS em claro (o candidato a ACS leva só has_cns).
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

    # <household> da versão `version` (a última). full: false (lista) sem
    # living_conditions. families: as Family do domicílio (com o responsável).
    def household(household, version, families:, full: true)
      json = { id: household.id, micro_area: { id: household.micro_area.id, code: household.micro_area.code },
               address: address(version.address), property_type: version.property_type, contact_phone: version.contact_phone,
               refused: version.refused?, status: household.status, version: household.version,
               registered_at: household.registered_at.iso8601, registered_by: { name: household.registered_by_user.professional&.professional_name },
               families: families.map { |row| family(row) } }
      json[:living_conditions] = version.living_conditions.to_h if full
      json
    end

    # Endereço com as chaves do TerritoryRegistry::Address (vazio com recusa sem endereço).
    def address(values)
      values = values.to_h
      values.empty? ? {} : Address::KEYS.to_h { |key| [ key, values[key] ] }
    end

    def family(family)
      patient = family.responsible_patient
      { id: family.id, responsible: { patient_id: patient.id, display_name: patient.display_name }, income_band: family.income_band,
        members_count: family.members_count, living_since: family.living_since, moved_out: family.moved_out }
    end

    def acs_candidate(professional)
      { professional_id: professional.id, name: professional.professional_name,
        has_cns: Professionals::Cns.valid?(professional.cns) }
    end
  end
end
