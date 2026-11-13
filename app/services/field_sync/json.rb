# Formas JSON do aparelho de campo e da sessão do app (módulo 24b, ADR 0052;
# contrato §9.1, §9.3). Nunca o token nem o digest.
module FieldSync
  module Json
    module_function

    # { user_id => "active" | "inactive" } dos donos dos aparelhos: inactive =
    # usuário desativado ou sem vínculo ativo da Tabela 7 em equipe ativa 70/76
    # (Q7; calculado na leitura, sem revogar — quem revoga é a próxima
    # requisição do app). Uma conta por dono, não por aparelho.
    def owner_states(devices)
      devices.map(&:user).uniq.to_h do |user|
        [ user.id, user.active? && HomeVisits::Access.device_owner?(user) ? "active" : "inactive" ]
      end
    end

    def device(device, owner_state:)
      { id: device.id, name: device.name, created_at: device.created_at.iso8601, last_used_at: device.last_used_at&.iso8601,
        status: device.revoked? ? "revoked" : owner_state, revoked_at: device.revoked_at&.iso8601, revoked_reason: device.revoked_reason }
    end

    # Lista com `status` (e `user: { id, name }` na do administrador).
    def devices(devices, with_user: false)
      states = owner_states(devices)
      devices.map do |record|
        json = device(record, owner_state: states.fetch(record.user_id))
        with_user ? json.merge(user: { id: record.user_id, name: record.professional.professional_name }) : json
      end
    end

    # GET /field/v1/session (session-response-v1): as equipes ativas 70/76 em
    # que o dono tem papel de campo (ACS ou outro CBO da Tabela 7), com as
    # microáreas ATIVAS do escopo (responsible | assigned; Q26). `member` é o
    # vínculo que autenticou (HomeVisits::Access.device_owner?).
    def session(user:, member:, city:, today: Time.zone.today, now: Time.current)
      { contract: Catalog::CONTRACT, server_time: now.iso8601, user: { id: user.id, name: user.professional.professional_name },
        professional: { id: user.professional.id, cbo: member.cbo_code, has_cns: user.professional.cns.present? },
        teams: field_teams(user).map { |team, role| team_json(user, team, role) },
        features: { home_visits: HomeVisits::Gate.usable?(city), collective_activities: CollectiveActivities::Gate.usable?(city),
                    territory_registry: TerritoryRegistry::Gate.usable?(city) },
        min_date: HomeVisits::Rules.min_date(today).iso8601 }
    end

    # [[equipe, papel]] com papel :acs ou :field (ordem: nome, INE).
    def field_teams(user)
      team_ids = HealthTeamMember.active.where(professional: user.professional).pluck(:health_team_id)
      HealthTeam.where(id: team_ids, active: true, kind: TerritoryRegistry::Catalog::TEAM_KINDS).order(:name, :ine).filter_map do |team|
        role = HomeVisits::Access.role(HomeVisits::Access.member(user, team))
        [ team, role ] if %i[acs field].include?(role)
      end
    end

    # <household> do app: a forma do 24a (famílias e moradia, full), sem a
    # família de responsável provisório da UPA (Q47, M3: o <family> exige
    # responsible com patient_id e display_name; a visita family_responsible a
    # ela já é recusada pela guarda da Q41). A única montagem do download
    # (FieldSync::Changes) e do `current` do stale_version (FieldSync::Upload).
    # `families`: as do domicílio, com :responsible_patient; `version`: a
    # última (lida aqui se não vier); `exited`: os ids de
    # TerritoryRegistry::Families.responsible_exited_ids (calculados aqui se
    # não vierem; o download calcula de uma vez para a página). Os
    # responsáveis mostrados (a trilha) são os de `body[:families]`.
    def household_body(household, families, version: nil, exited: nil)
      kept = families.reject { |family| provisional?(family.responsible_patient) }
      version ||= HouseholdVersion.find_by!(household_id: household.id, version: household.version)
      exited ||= TerritoryRegistry::Families.responsible_exited_ids(kept)
      TerritoryRegistry::Json.household(household, version, families: kept, exited: exited, full: true)
    end

    # Os responsáveis das famílias de um <household> (a trilha de quem o mostra).
    def household_responsible_ids(body) = body.fetch(:families).map { |family| family.dig(:responsible, :patient_id) }

    # A guarda da Q41 (HomeVisits::People): no_cpf_reason é cifrado, então o
    # fluxo do download corta só por `unidentified` (indexado) e esta
    # conferência fecha o resto.
    def provisional?(patient) = patient.unidentified || patient.no_cpf_reason == "unidentified"

    def team_json(user, team, role)
      scope = HomeVisits::Access.scope(user, team)
      areas = MicroArea.where(id: scope[:micro_area_ids], active: true).order(:code)
      { id: team.id, ine: team.ine, name: team.name,
        micro_areas: areas.map { |area| HomeVisits::Json.micro_area(area).merge(scope: scope[:kind]) },
        out_of_area_allowed: role == :acs }
    end
    private_class_method :field_teams, :team_json
  end
end
