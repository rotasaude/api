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

    # <registration> (contrato §2, §14 L4, L7, L9) da versão `version` (a
    # última). Status direto até a Task 12 (TerritoryRegistry::Validity).
    # identity_locked: o paciente tem par validado (nome, nascimento, sexo e
    # mãe só leitura). CNS só mascarado (L8).
    def registration(registration, version, identity_locked:)
      patient = registration.patient
      area = registration.micro_area
      { id: registration.id,
        patient: { id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, sex: patient.sex,
                   has_cpf: patient.cpf.present?, no_cpf_reason: patient.no_cpf_reason, cns_masked: patient.cns_masked,
                   identity_locked: identity_locked },
        patient_demographics: { race_color: patient.race_color, ethnicity: patient.ethnicity },
        household_id: registration.household_id, family_id: registration.family_id, is_responsible: registration.is_responsible,
        team: team_ref(registration.team), micro_area: area && { id: area.id, code: area.code },
        identification: version.identification.to_h, sociodemographic: version.sociodemographic.to_h,
        health_conditions: version.health_conditions.to_h, street_situation: version.street_situation,
        refused: registration.refused?, exit: registration_exit(registration), status: registration_status(registration),
        version: registration.version, registered_at: registration.registered_at.iso8601,
        registered_by: { name: registration.registered_by_user.professional&.professional_name },
        identity_changed_at: registration.identity_changed_at&.iso8601 }
    end

    def registration_exit(registration)
      return nil unless registration.exited?

      { reason: registration.exit_reason, on: registration.exited_on.iso8601, death_on: registration.death_on&.iso8601,
        death_certificate: registration.death_certificate }
    end

    def registration_status(registration)
      return "exited" if registration.exited?

      registration.refused? ? "refused" : "valid"
    end

    # Candidato a duplicado (contrato §5): sem CPF, CNS nem mãe.
    def duplicate(patient)
      { patient_id: patient.id, display_name: patient.display_name, birth_date: patient.birth_date, has_cpf: patient.cpf.present? }
    end

    # Equipe do profissional (L2) com as microáreas ativas; can_register por
    # microárea (ids do Access.registrar? :ok).
    def professional_team(team, areas, can_register:)
      team_ref(team).merge(unit: { id: team.health_unit.id, name: team.health_unit.name },
                           micro_areas: areas.map { |area| micro_area(area).merge(can_register: can_register.include?(area.id)) })
    end

    def acs_candidate(professional)
      { professional_id: professional.id, name: professional.professional_name,
        has_cns: Professionals::Cns.valid?(professional.cns) }
    end
  end
end
