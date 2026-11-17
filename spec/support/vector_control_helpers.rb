# Módulo 35a (ADR 0054): cidade com a visita domiciliar e a vigilância
# ambiental ligadas, o agente de combate às endemias (515140) atribuído a uma
# microárea, a coordenação, o laboratório, quarteirões e perfis de imóvel. Os
# helpers das tasks seguintes entram neste arquivo.
module VectorControlHelpers
  def vector_city!
    city = home_visit_city!
    Platform::Features.set!(city: city, key: VectorControl::Gate::KEY, enabled: true, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    city
  end

  # ACE (515140) com vínculo ativo na equipe (nova, se não vier) e atribuído a
  # uma microárea nova dela pelo enfermeiro da equipe.
  def endemic_agent!(team: nil)
    agent = field_agent!(cbo: TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO, team: team)
    team ||= HealthTeamMember.active.find_by!(professional: agent.professional).health_team
    area = registry_micro_area!(code: vector_micro_area_code(team), team: team)
    assignment!(area, agent.professional)
    agent
  end

  def endemic_coordinator! = staff_with("endemias-#{SecureRandom.hex(4)}@cidade.gov.br", "endemic_coordinator")

  def vector_lab! = staff_with("entomologia-#{SecureRandom.hex(4)}@cidade.gov.br", "vector_lab")

  def city_block!(neighborhood:, number:)
    CityBlock.create!(neighborhood: neighborhood, number: number, created_by_user: vector_author)
  end

  # Perfil do imóvel direto na linha; com risco, avaliado hoje (CHECK).
  def vector_profile!(household, block:, risk: nil)
    HouseholdVectorProfile.create!(household: household, city_block: block, risk_class: risk,
                                   risk_assessed_on: risk && Time.zone.today, updated_by_user: vector_author)
  end

  private

  def vector_author = (@vector_author ||= endemic_coordinator!)

  # Código livre da equipe, de 99 para baixo (os specs usam 01, 02, …).
  def vector_micro_area_code(team)
    taken = MicroArea.where(team_id: team.id).pluck(:code)
    format("%02d", 99.downto(1).find { |n| !taken.include?(format("%02d", n)) })
  end
end

RSpec.configure { |c| c.include VectorControlHelpers }
