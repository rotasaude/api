# Módulo 24b (ADR 0052): cidade das visitas (cadastro territorial + `home_visits`,
# e `collective_activities` se pedido), agente de campo (qualquer CBO da Tabela 7),
# folha do dia, visita e atribuição de microárea. A folha e a visita nascem direto
# nas linhas (create!) até a Task 8; `home_visit!` passa a usar o
# HomeVisits::Record a partir dali. Tudo avaliado só na chamada.
module HomeVisitHelpers
  # `registry_city!` (prontuário, PEC falso, territory_registry) e os interruptores.
  def home_visit_city!(collective: false)
    city = registry_city!
    Platform::Features.set!(city: city, key: HomeVisits::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    if collective
      Platform::Features.set!(city: city, key: CollectiveActivities::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    end
    CityCatalog.reset_cache!
    city
  end

  # Usuário `health_professional` com vínculo ativo na equipe e o CBO dado. O
  # vínculo com a unidade (ProfessionalLink) só aceita CBO do catálogo da
  # plataforma (config/professionals/cbo_saude.yml), que não tem todos da
  # Tabela 7 (322255 TACS, 515310…); o da equipe (HealthTeamMember, vindo do
  # CNES) aceita: fora do catálogo, a unidade leva o 515105 e a equipe o CBO dado.
  def field_agent!(cbo: HomeVisits::Catalog::ACS_CBO, team: nil)
    linkable = Professionals::Cbo.all.any? { |row| row.code == cbo }
    user = registry_field_professional!(team&.health_unit, team: team, cbo: linkable ? cbo : HomeVisits::Catalog::ACS_CBO,
                                        council: false)
    HealthTeamMember.active.where(professional: user.professional).update_all(cbo_code: cbo) unless linkable
    user
  end

  # Folha direto nas linhas. `agent` é o usuário (field_agent!); a equipe é a do
  # vínculo ativo, se não vier.
  def home_visit_day!(agent: nil, team: nil, day: Time.zone.today, sequence: 1, state: "open", validate: true, **over)
    agent ||= field_agent!(team: team)
    member = HealthTeamMember.active.find_by!(professional: agent.professional, **(team ? { health_team: team } : {}))
    closed = state == "closed" ? { closed_at: Time.current, closed_by: "user", closed_by_user: agent } : {}
    record = HomeVisitDay.new({ professional: agent.professional, user: agent, team: member.health_team, cbo: member.cbo_code,
                                day: day, sequence: sequence, state: state, **closed }.merge(over))
    record.save!(validate: validate)
    record
  end

  # Visita direto nas linhas: ao imóvel (subject "none"), fora de área, a menos
  # que venha microárea. `over` sobrescreve qualquer coluna.
  # `validate: false` grava sem as validações do modelo (para provar o CHECK do banco).
  def home_visit!(day: nil, micro_area: nil, occurred_at: nil, validate: true, **over)
    day ||= home_visit_day!
    occurred_at ||= day.day.in_time_zone.change(hour: 9)
    area = micro_area ? { micro_area: micro_area, out_of_area: false } : { micro_area: nil, out_of_area: true }
    visit = HomeVisit.new({ home_visit_day: day, client_uuid: SecureRandom.uuid, occurred_at: occurred_at, shift: 1,
                        subject: "none", property_type: "1", outcome: 1, has_reason: false, origin: "dashboard",
                        recorded_by_user: day.user, **area }.merge(over))
    visit.save!(validate: validate)
    visit
  end

  def assignment!(micro_area, professional, by: nil)
    MicroAreaFieldAssignment.create!(micro_area: micro_area, professional: professional,
                                     assigned_by_user: by || registry_nurse!(micro_area.team.health_unit, team: micro_area.team))
  end
end

RSpec.configure { |c| c.include HomeVisitHelpers }
