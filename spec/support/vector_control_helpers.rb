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

  # Task 7 (contrato §4): produto de campo, o local vector_control numa UVZ
  # (unidade environmental_surveillance), o lote com saldo pelo caminho real
  # do 27a (Pharmacy::RecordEntry: a abertura se o produto ainda não tem
  # abertura no local, senão uma nota) e o local escolhido para a baixa.
  def vector_product!(code: "P#{SecureRandom.hex(3).upcase}", name: "Pyriproxyfen 0,5% G", unit: "g", charge_size: "2.00",
                      uses: %w[focal], active: true)
    VectorProduct.create!(code: code, name: name, unit: unit, charge_size: BigDecimal(charge_size), uses: uses, active: active)
  end

  def vector_location!(unit = create_unit("UVZ #{SecureRandom.hex(2)}", kind: "environmental_surveillance"), name: nil)
    StockLocation.create!(kind: "vector_control", name: name || "Insumos #{unit.name}", health_unit: unit, updated_by_user: vector_author)
  end

  def vector_lot!(location, product:, quantity: "10", lot_number: "L#{SecureRandom.hex(3).upcase}", expires_on: Time.zone.today + 180, by: nil)
    by ||= vector_author
    opening = !StockOpening.exists?(stock_location_id: location.id, vector_product_id: product.id)
    result = Pharmacy::RecordEntry.call(
      location: location, kind: opening ? "opening" : "invoice",
      document: { "number" => "NF-#{SecureRandom.hex(3)}", "supplier" => "Distribuidora de Teste" },
      items: [ { "vector_product_id" => product.id, "lot_number" => lot_number, "expires_on" => expires_on.to_date.iso8601,
                 "quantity" => quantity.to_s } ],
      by: by, catalog: {}, now: [ Time.current, expires_on.to_date.in_time_zone ].min
    )
    raise ArgumentError, "vector_lot!: #{result.reason} #{result.details.inspect}" if result.failure?

    StockLot.find_by!(vector_product_id: product.id, lot_number: lot_number)
  end

  def vector_stock_location!(location)
    VectorControlSetting.ensure_defaults!
    VectorControlSetting.find(1).update!(stock_location_id: location&.id)
  end

  # Visita trabalhada pelo caminho real (HomeVisits::Record com o boletim e uma
  # medida focal do produto): a baixa ou a falta, conforme o estoque. -> HomeVisit
  def vector_visit!(product:, charges: 1, agent: nil, household: nil)
    agent ||= endemic_agent!
    member = HealthTeamMember.active.find_by!(professional: agent.professional)
    household ||= registry_household!(micro_area: MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area)
    report = { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
               "measures" => [ { "method" => "focal", "vector_product_id" => product.id, "charges" => charges } ] }
    params = { "client_uuid" => SecureRandom.uuid, "team_id" => member.health_team_id, "occurred_at" => Time.current.change(usec: 0).iso8601,
               "household_id" => household.id, "subject" => "none", "outcome" => 1, "reasons" => [], "shared" => false,
               "vector_inspection" => report }
    result = HomeVisits::Record.call(params: params, by: agent, vector_control: true)
    raise ArgumentError, "vector_visit!: #{result.reason} #{result.details.inspect}" if result.failure?

    result.payload[:visit]
  end

  # A falta da medida da visita (a visita nasce sem estoque bastante).
  def vector_shortfall!(product:, **opts)
    visit = vector_visit!(product: product, **opts)
    VectorStockShortfall.joins(vector_inspection_measure: :vector_inspection).find_by!(vector_inspections: { home_visit_id: visit.id })
  end

  # Almoxarife (stock_keeper) com vínculo ativo ao local.
  def vector_keeper!(location)
    user = staff_with("almoxarife-uvz-#{SecureRandom.hex(3)}@cidade.gov.br", "stock_keeper")
    StockLocationStaff.create!(stock_location: location, user: user, role: "stock_keeper", granted_by_user: pharmacy_admin!, granted_at: Time.current)
    user
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
