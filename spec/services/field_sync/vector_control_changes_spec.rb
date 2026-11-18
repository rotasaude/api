require "rails_helper"

# Módulo 35a, Task 15 (ADR 0054; contrato §13; Q6; W-14; plano, Review Focus
# 5): o download do app de campo na v1.3.0. Só com o gate vector_control
# utilizável saem city_block, ovitrap, liraa_item, transmission_block e o
# `<household>.vector` (null = imóvel sem perfil); sem ele, nada disso e o
# <household> sem a chave. O gate entra no scope_digest: ligar ou desligar com
# cursor antigo → reset: true e carga do zero. Toda página validada contra o
# changes-response-v1 da v1.3.0; nenhum bloqueio leva caso, notificação ou
# paciente.
RSpec.describe "FieldSync::Changes — vigilância ambiental (v1.3.0)", type: :model do
  def max_pages = 12

  let!(:city) { vector_city! }
  let(:team) { registry_team! }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional_id: agent.professional.id).micro_area }
  let(:device) { FieldDevices::Register.call(user: agent, name: "Tablet").payload.fetch(:device) }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:coordinator) { endemic_coordinator! }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def fetch(cursor = nil, limit: 200)
    FieldSync::Changes.page(user: agent, device: device, cursor: cursor, limit: limit, now: Time.current + 3.seconds)
  end

  def all_pages(cursor = nil, limit: 200)
    pages = []
    max_pages.times do
      page = JSON.parse(fetch(cursor, limit: limit).to_json)
      expect(FieldSync::Schemas.errors("changes-response-v1", page)).to eq([])
      pages << page
      cursor = page.fetch("next_cursor")
      return pages unless page.fetch("has_more")
    end
    raise "paginação passou de #{max_pages} páginas"
  end

  def items(pages) = pages.flat_map { _1.fetch("items") }
  def of(pages, type) = items(pages).select { _1.fetch("type") == type }
  def refs(pages, type) = of(pages, type).map { _1.fetch("id") }
  def body_of(pages, type, id) = of(pages, type).find { _1.fetch("id") == id }&.fetch("body")
  def vector_types = %w[city_block ovitrap liraa_item transmission_block]

  def gate!(enabled)
    Platform::Features.set!(city: Current.city, key: VectorControl::Gate::KEY, enabled: enabled, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
  end

  describe "Review Focus 5" do
    it "cursor antigo e gate ligado → reset true, com city_block, ovitrap e <household>.vector; desligar → reset true sem nada disso" do
      profiled = ovitrap_household!(agent, block: block)
      bare = registry_household_rows!(area, neighborhood_id: neighborhood.id)
      other = city_block!(neighborhood: neighborhood, number: "13")
      ovitrap = ovitrap_installed!(agent: agent, household: profiled)
      gate!(false)

      off = all_pages
      expect(items(off).map { _1["type"] }.uniq).to contain_exactly("micro_area", "household")
      expect(of(off, "household").map { _1.fetch("body") }).to all(satisfy { |body| !body.key?("vector") })
      cursor = off.last.fetch("next_cursor")
      expect(fetch(cursor)).to include(reset: false, items: [])

      gate!(true)
      on = all_pages(cursor)
      expect(on.first.fetch("reset")).to be(true)
      expect(on.drop(1).map { _1.fetch("reset") }.uniq).to eq([ false ]) if on.size > 1
      expect(refs(on, "city_block")).to contain_exactly(block.id, other.id)
      expect(body_of(on, "city_block", block.id)).to eq("id" => block.id, "neighborhood_id" => neighborhood.id, "number" => "12",
                                                         "active" => true, "neighbor_ids" => [], "version" => 1)
      expect(body_of(on, "ovitrap", ovitrap.id)).to eq("id" => ovitrap.id, "number" => ovitrap.number, "household_id" => profiled.id,
                                                        "status" => "active", "open_reading" => { "installed_on" => ovitrap.installed_on.iso8601 },
                                                        "last_reading" => nil, "version" => 1)
      expect(body_of(on, "household", profiled.id).fetch("vector")).to eq("city_block_id" => block.id, "risk_class" => nil, "risk_assessed_on" => nil,
                                                                         "last_worked_on" => nil, "last_situation" => nil)
      expect(body_of(on, "household", bare.id)).to include("vector" => nil)
      next_cursor = on.last.fetch("next_cursor")

      gate!(false)
      again = all_pages(next_cursor)
      expect(again.first.fetch("reset")).to be(true)
      expect(items(again).map { _1["type"] } & vector_types).to eq([])
      expect(of(again, "household").map { _1.fetch("body") }).to all(satisfy { |body| !body.key?("vector") })
    end

    it "vizinho novo reemite os dois quarteirões na página seguinte; leitura nova reemite a ovitrampa; perfil novo reemite o <household>" do
      household = ovitrap_household!(agent, block: block)
      neighbor = city_block!(neighborhood: neighborhood, number: "13")
      far = city_block!(neighborhood: neighborhood, number: "14")
      ovitrap = ovitrap_installed!(agent: agent, household: household, installed_on: Time.zone.today - 5)
      cursor = all_pages.last.fetch("next_cursor")

      expect(VectorControl::LinkNeighbor.add(block: block, neighbor_block_id: neighbor.id, by: coordinator)).to be_ok
      ovitrap_collected!(ovitrap, agent: agent, collected_on: Time.zone.today)
      HouseholdVectorProfile.find_by!(household_id: household.id).update!(risk_class: "red", risk_assessed_on: Time.zone.today)

      pages = all_pages(cursor)
      expect(pages.first.fetch("reset")).to be(false)
      expect(refs(pages, "city_block")).to contain_exactly(block.id, neighbor.id)
      expect(refs(pages, "city_block")).not_to include(far.id)
      expect(body_of(pages, "city_block", block.id)).to include("neighbor_ids" => [ neighbor.id ], "version" => 2)
      expect(body_of(pages, "city_block", neighbor.id)).to include("neighbor_ids" => [ block.id ], "version" => 2)
      expect(body_of(pages, "ovitrap", ovitrap.id)).to include(
        "open_reading" => { "installed_on" => Time.zone.today.iso8601 },
        "last_reading" => { "collected_on" => Time.zone.today.iso8601, "condition" => "ok", "egg_count" => nil }, "version" => 2
      )
      expect(refs(pages, "household")).to eq([ household.id ])
      expect(body_of(pages, "household", household.id).dig("vector", "risk_class")).to eq("red")
    end

    it "levantamento fechado → cada item uma vez com status closed" do
      liraa_parameters!(liraa_standard_min: 10, liraa_standard_max: 100, liraa_half_min: 5)
      liraa_households!(block, 12, micro_area: area)
      survey = liraa_survey!([ { mode: "standard", blocks: [ block ] } ])
      draft = all_pages
      expect(of(draft, "liraa_item")).to eq([])
      expect(VectorControl::Liraa::Draw.call(survey: survey, by: coordinator, random: fixed_random(1))).to be_ok
      drawn = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: survey.id }).to_a
      expect(drawn.size).to eq(3)

      open = all_pages(draft.last.fetch("next_cursor"))
      expect(refs(open, "liraa_item")).to match_array(drawn.map(&:id))
      first = drawn.first
      expect(body_of(open, "liraa_item", first.id)).to eq("id" => first.id, "survey_id" => survey.id, "survey_name" => survey.name,
                                                          "household_id" => first.household_id, "city_block_id" => block.id,
                                                          "status" => "pending", "version" => 1)

      expect(VectorControl::Liraa::Close.call(survey: survey.reload, by: coordinator)).to be_ok
      closed = all_pages(open.last.fetch("next_cursor"), limit: 1)
      expect(refs(closed, "liraa_item")).to match_array(drawn.map(&:id))
      expect(refs(closed, "liraa_item").size).to eq(3)
      expect(of(closed, "liraa_item").map { _1.dig("body", "status") }.uniq).to eq([ "closed" ])
      expect(of(all_pages(closed.last.fetch("next_cursor")), "liraa_item")).to eq([])
    end

    it "bloqueio proposed não vai; active vai; ciclo novo o reemite; closed vai uma vez; nenhum leva case, notification ou patient" do
      ovitrap_household!(agent, block: block)
      outside = city_block!(neighborhood: Neighborhood.create!(name: "Longe #{SecureRandom.hex(3)}", source: "manual"), number: "1")
      proposed = TransmissionBlock.create!(disease_group: "arbovirus", center_block: block)
      TransmissionBlockArea.create!(transmission_block: proposed, city_block: block)
      active = TransmissionBlock.create!(disease_group: "arbovirus", center_block: block)
      expect(VectorControl::Blocks::Confirm.call(block: active, center_block_id: block.id, block_ids: [ block.id ], seen_case_ids: [],
                                                 by: coordinator)).to be_ok
      elsewhere = TransmissionBlock.create!(disease_group: "arbovirus", center_block: outside)
      expect(VectorControl::Blocks::Confirm.call(block: elsewhere, center_block_id: outside.id, block_ids: [ outside.id ], seen_case_ids: [],
                                                 by: coordinator)).to be_ok

      first = all_pages
      expect(refs(first, "transmission_block")).to eq([ active.id ])
      expect(body_of(first, "transmission_block", active.id)).to eq("id" => active.id, "status" => "active", "block_ids" => [ block.id ],
                                                                    "cycles" => [], "version" => active.reload.version)

      expect(VectorControl::Blocks::AddCycle.call(block: active, starts_on: Time.zone.today.iso8601, ends_on: (Time.zone.today + 2).iso8601,
                                                  by: coordinator)).to be_ok
      cycled = all_pages(first.last.fetch("next_cursor"))
      expect(refs(cycled, "transmission_block")).to eq([ active.id ])
      expect(body_of(cycled, "transmission_block", active.id).fetch("cycles"))
        .to eq([ { "number" => 1, "starts_on" => Time.zone.today.iso8601, "ends_on" => (Time.zone.today + 2).iso8601 } ])

      expect(VectorControl::Blocks::Close.call(block: active.reload, by: coordinator)).to be_ok
      closed = all_pages(cycled.last.fetch("next_cursor"))
      expect(of(closed, "transmission_block").map { [ _1["id"], _1.dig("body", "status") ] }).to eq([ [ active.id, "closed" ] ])
      expect(of(all_pages(closed.last.fetch("next_cursor")), "transmission_block")).to eq([])

      bodies = [ first, cycled, closed ].flat_map { of(_1, "transmission_block") }.map { _1.fetch("body") }
      expect(bodies.flat_map(&:keys).uniq).to contain_exactly("id", "status", "block_ids", "cycles", "version")
      expect(bodies.to_json).not_to match(/case|notification|patient/)
    end
  end

  # Fix round 1: as entidades do 35a entram no escopo por junção (domicílio,
  # versão atual, perfil). Cursor antigo, a mudança, e a página seguinte traz a
  # entidade (o `t` leva o instante de junção dos membros, VECTOR_SCOPE).
  describe "entrada no escopo por domicílio ou perfil" do
    let(:nurse) { registry_nurse!(team: team) }
    let(:fresh) { Neighborhood.create!(name: "Novo #{SecureRandom.hex(3)}", source: "manual") }

    # A microárea tocada agora vai por último na carga: o cursor passa de tudo o
    # que já existe (sem isso, o quarteirão gravado depois da última linha
    # emitida sairia de qualquer jeito, pelo próprio updated_at).
    def cursor_now
      area.touch
      all_pages.last.fetch("next_cursor")
    end

    def save_household!(household, **changes)
      params = registry_household_params(household).merge("version" => household.reload.version)
      params = params.merge(changes.transform_keys(&:to_s)) { |_key, old, new| old.is_a?(Hash) ? old.merge(new) : new }
      result = TerritoryRegistry::SaveHousehold.call(params: params, by: nurse, household: household)
      raise "domicílio recusado: #{result.reason} #{result.details}" if result.failure?
    end

    it "(a) domicílio novo num bairro sem outro domicílio do escopo → os quarteirões dele chegam" do
      ovitrap_household!(agent, block: block)
      blocks = [ city_block!(neighborhood: fresh, number: "1"), city_block!(neighborhood: fresh, number: "2") ]
      cursor = cursor_now
      registry_household_rows!(area, neighborhood_id: fresh.id)
      expect(refs(all_pages(cursor), "city_block")).to match_array(blocks.map(&:id))
    end

    it "(b) o endereço do domicílio muda para um bairro novo → os quarteirões chegam" do
      household = registry_household!(micro_area: area)
      fresh_block = city_block!(neighborhood: fresh, number: "1")
      cursor = cursor_now
      expect(refs(all_pages(cursor.dup), "city_block")).to eq([])
      save_household!(household, address: { "neighborhood_id" => fresh.id })
      expect(household.reload.latest_version.neighborhood_id).to eq(fresh.id)
      expect(refs(all_pages(cursor), "city_block")).to eq([ fresh_block.id ])
    end

    it "(c) AssignBlock num quarteirão de bloqueio ativo → o bloqueio chega" do
      household = registry_household_rows!(area, neighborhood_id: neighborhood.id)
      target = city_block!(neighborhood: neighborhood, number: "40")
      active = TransmissionBlock.create!(disease_group: "arbovirus", center_block: target)
      expect(VectorControl::Blocks::Confirm.call(block: active, center_block_id: target.id, block_ids: [ target.id ], seen_case_ids: [],
                                                 by: coordinator)).to be_ok
      cursor = cursor_now
      expect(refs(all_pages, "transmission_block")).to eq([])
      expect(VectorControl::AssignBlock.call(household_ids: [ household.id ], city_block_id: target.id, by: coordinator)).to be_ok
      pages = all_pages(cursor)
      expect(refs(pages, "transmission_block")).to eq([ active.id ])
      expect(body_of(pages, "household", household.id).dig("vector", "city_block_id")).to eq(target.id)
    end

    it "(d) domicílio que muda para uma microárea do escopo → a ovitrampa e o item pendente do LIRAa chegam" do
      other = endemic_agent!(team: team)
      other_area = MicroAreaFieldAssignment.active.find_by!(professional_id: other.professional.id).micro_area
      liraa_parameters!(liraa_standard_min: 10, liraa_standard_max: 100, liraa_half_min: 5)
      liraa_households!(block, 12, micro_area: other_area)
      survey = liraa_survey!([ { mode: "standard", blocks: [ block ] } ])
      expect(VectorControl::Liraa::Draw.call(survey: survey, by: coordinator, random: fixed_random(1))).to be_ok
      item = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: survey.id }).order(:position).first
      household = Household.find(item.household_id)
      ovitrap = ovitrap_installed!(agent: other, household: household)
      registry_household_rows!(area) # o agente já baixa algo; o cursor é de uma carga real
      cursor = cursor_now

      save_household!(household, micro_area_id: area.id)
      pages = all_pages(cursor)
      expect(pages.first.fetch("reset")).to be(false)
      expect(refs(pages, "ovitrap")).to eq([ ovitrap.id ])
      expect(refs(pages, "liraa_item")).to eq([ item.id ])
      expect(body_of(pages, "liraa_item", item.id)).to include("status" => "pending")
      expect(refs(pages, "city_block")).to eq([ block.id ])
    end

    it "(e) carga completa: perfil cujo quarteirão ficou noutro bairro depois de uma mudança do 24a → o quarteirão vai" do
      household = registry_household_rows!(area, neighborhood_id: fresh.id)
      vector_profile!(household, block: block) # block fica no `neighborhood`, não no `fresh`
      pages = all_pages
      expect(refs(pages, "city_block")).to eq([ block.id ])
      expect(body_of(pages, "household", household.id).dig("vector", "city_block_id")).to eq(block.id)
    end

    it "membro que sai não faz a linha andar para trás nem a reemite" do
      stays = registry_household_rows!(area, neighborhood_id: neighborhood.id)
      leaves = registry_household_rows!(area, neighborhood_id: neighborhood.id)
      block
      cursor = cursor_now
      elsewhere = MicroAreaFieldAssignment.active.find_by!(professional_id: endemic_agent!(team: team).professional.id).micro_area
      save_household!(leaves, micro_area_id: elsewhere.id)
      pages = all_pages(cursor)
      expect(refs(pages, "household")).to eq([])
      expect(refs(pages, "city_block")).to eq([])
      full = all_pages
      expect(refs(full, "household")).to eq([ stays.id ])
      expect(refs(full, "city_block")).to eq([ block.id ])
    end
  end

  it "gate desligado → nenhuma entidade nova e <household> sem a chave vector; ligado, imóvel sem perfil → vector: null (Q6)" do
    household = ovitrap_household!(agent, block: block)
    bare = registry_household_rows!(area)
    ovitrap_installed!(agent: agent, household: household)
    gate!(false)
    off = all_pages
    expect(items(off).map { _1["type"] } & vector_types).to eq([])
    expect(of(off, "household").map { _1.fetch("body").key?("vector") }.uniq).to eq([ false ])

    gate!(true)
    on = all_pages
    expect(on.first.fetch("reset")).to be(false) # sem cursor: carga completa, não reset
    expect(body_of(on, "household", bare.id).fetch("vector")).to be_nil
    expect(body_of(on, "household", household.id).fetch("vector")).to include("city_block_id" => block.id)
    expect(items(on).map { _1["type"] }).to include("city_block", "ovitrap")
  end

  it "o scope_digest muda com o gate (W-14), só com ids de microárea e o marcador" do
    off = FieldSync::Scope.for(agent, vector_control: false)
    on = FieldSync::Scope.for(agent, vector_control: true)
    expect(off[:micro_area_ids]).to eq(on[:micro_area_ids])
    expect(off[:digest]).to eq(Digest::SHA256.hexdigest(off[:micro_area_ids].join(",")))
    expect(on[:digest]).to eq(Digest::SHA256.hexdigest("#{on[:micro_area_ids].join(',')},vector_control"))
  end
end
