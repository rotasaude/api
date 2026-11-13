require "rails_helper"

# Módulo 24b (ADR 0052; contrato §9.3, §16 Q9, Q33, Q47, Q60, Q61, C12;
# Ruling A12; preflight 22): o download incremental do app de campo.
# Escopo = microáreas ativas em que o dono do aparelho é o ACS responsável ou
# tem atribuição ativa (FieldSync::Scope). Um fluxo só, ordenado por (tempo,
# id): microáreas, domicílios e cadastros pelo updated_at, lápides pelo
# created_at (contam no limit e saem em removals da página em que caem), com
# corte em agora − 2 s. Escopo diferente do cursor → reset: true e carga do
# zero. who_to_visit só na última página. Trilha por página com pessoa.
# Todo laço de paginação tem teto fixo (max_pages).
RSpec.describe FieldSync::Changes, type: :model do
  def max_pages = 12

  let!(:city) { home_visit_city! }
  let(:unit) { care_unit! }
  let(:team) { registry_team!(unit) }
  let(:acs) { registry_acs!(unit, team: team) }
  let!(:area) { registry_micro_area!(code: "01", team: team, acs: acs) }
  let!(:foreign_area) { registry_micro_area!(code: "02", team: team, acs: registry_acs!(unit, team: team)) }
  let(:nurse) { registry_nurse!(unit, team: team) }
  let(:device) { FieldDevices::Register.call(user: acs, name: "Celular").payload.fetch(:device) }

  # O corte de 2 s: o que acabou de ser gravado só sai depois dele.
  def fetch(cursor = nil, user: acs, on: device, limit: 200)
    described_class.page(user: user, device: on, cursor: cursor, limit: limit, now: Time.current + 3.seconds)
  end

  def wire(page) = JSON.parse(page.to_json)

  # Páginas até has_more: false, cada uma conferida contra o esquema.
  def all_pages(cursor = nil, **opts)
    pages = []
    max_pages.times do
      page = wire(fetch(cursor, **opts))
      expect(FieldSync::Schemas.errors("changes-response-v1", page)).to eq([])
      pages << page
      cursor = page.fetch("next_cursor")
      return pages unless page.fetch("has_more")
    end
    raise "paginação passou de #{max_pages} páginas"
  end

  def refs(pages) = pages.flat_map { |page| page.fetch("items").map { |item| [ item.fetch("type"), item.fetch("id") ] } }
  def removals(pages) = pages.flat_map { |page| page.fetch("removals").map { |row| [ row.fetch("type"), row.fetch("id"), row.fetch("reason") ] } }
  def field_trail = DomainEvent.where(name: "clinical_record.viewed").order(:created_at, :id).select { |event| event.payload["access"] == "field_sync" }

  def move_household!(household, target)
    result = TerritoryRegistry::SaveHousehold.call(params: registry_household_params(household).merge("micro_area_id" => target.id, "version" => household.version),
                                                   by: nurse, household: household)
    raise "domicílio recusado: #{result.reason}" if result.failure?
  end

  it "carga completa do ACS traz só as suas microáreas, em páginas, sem repetir nem pular (empate de updated_at)" do
    households = Array.new(3) { registry_household!(micro_area: area) }
    registrations = [ registry_registration!(household: households[0]), registry_registration!(household: households[1]) ]
    foreign = registry_household!(micro_area: foreign_area)
    registry_registration!(household: foreign)
    # Todos no mesmo instante: o desempate é o id.
    tie = 1.minute.ago
    [ area, *households, *registrations ].each { |record| record.update_columns(updated_at: tie) }

    pages = all_pages(limit: 2)

    expected = [ [ "micro_area", area.id ], *households.map { [ "household", _1.id ] }, *registrations.map { [ "registration", _1.id ] } ]
    expect(refs(pages)).to eq(expected.sort_by(&:last))
    expect(pages.size).to eq(3)
    expect(pages.map { _1.fetch("reset") }.uniq).to eq([ false ])
    expect(pages.map { _1.fetch("has_more") }).to eq([ true, true, false ])
    household_body = pages.flat_map { _1.fetch("items") }.find { _1["id"] == households[0].id }
    expect(household_body).to include("version" => 1)
    expect(household_body.fetch("body")).to include("living_conditions", "families")
  end

  it "cursor seguinte traz só o que mudou e as removals" do
    second_area = registry_micro_area!(code: "03", team: team, acs: acs)
    kept, changed, leaving, inside = Array.new(4) { registry_household!(micro_area: area) }
    resident = registry_registration!(household: leaving)
    cursor = all_pages.last.fetch("next_cursor")

    changed_params = registry_household_params(changed).merge("contact_phone" => "4133335555", "version" => changed.version)
    expect(TerritoryRegistry::SaveHousehold.call(params: changed_params, by: acs, household: changed)).to be_ok
    move_household!(leaving, foreign_area)
    # Mudou de microárea DENTRO do escopo: lápide em 01, mas continua aqui → item, nunca removal.
    move_household!(inside, second_area)

    pages = all_pages(cursor)

    expect(refs(pages)).to contain_exactly([ "household", changed.id ], [ "household", inside.id ])
    expect(removals(pages)).to contain_exactly([ "household", leaving.id, "moved" ], [ "registration", resident.id, "moved" ])
    expect(pages.map { _1.fetch("reset") }.uniq).to eq([ false ])
    expect(refs(pages)).not_to include([ "household", kept.id ])

    # Lápide já entregue não volta.
    expect(all_pages(pages.last.fetch("next_cursor")).flat_map { _1.fetch("removals") }).to eq([])
  end

  it "lápide conta no limit e sai na página em que cai no fluxo" do
    first, second = Array.new(2) { registry_household!(micro_area: area) }
    cursor = all_pages.last.fetch("next_cursor")
    move_household!(first, foreign_area)
    second_params = registry_household_params(second).merge("contact_phone" => "4133335555", "version" => second.version)
    expect(TerritoryRegistry::SaveHousehold.call(params: second_params, by: acs, household: second)).to be_ok

    pages = all_pages(cursor, limit: 1)

    expect(pages.map { [ _1.fetch("items").size, _1.fetch("removals").size ] }).to eq([ [ 0, 1 ], [ 1, 0 ] ])
  end

  it "atribuição encerrada entre duas páginas → reset: true e a carga recomeça só com o escopo novo (Review Focus 4)" do
    agent = field_agent!(cbo: "322255", team: team)
    agent_device = FieldDevices::Register.call(user: agent, name: "Tablet").payload.fetch(:device)
    kept_area = registry_micro_area!(code: "05", team: team)
    lost_area = registry_micro_area!(code: "06", team: team)
    assignment!(kept_area, agent.professional, by: nurse)
    lost = assignment!(lost_area, agent.professional, by: nurse)
    kept_household = registry_household!(micro_area: kept_area)
    lost_household = registry_household!(micro_area: lost_area)

    first = wire(fetch(user: agent, on: agent_device, limit: 1))
    expect(first).to include("reset" => false, "has_more" => true)

    expect(HomeVisits::EndAssignment.call(assignment: lost, by: nurse)).to be_ok
    pages = all_pages(first.fetch("next_cursor"), user: agent, on: agent_device, limit: 1)

    expect(pages.first.fetch("reset")).to be(true)
    expect(pages.drop(1).map { _1.fetch("reset") }.uniq).to eq([ false ])
    expect(refs(pages)).to contain_exactly([ "micro_area", kept_area.id ], [ "household", kept_household.id ])
    expect(refs(pages).map(&:last)).not_to include(lost_area.id, lost_household.id)
    expect(pages.last.dig("who_to_visit", "micro_areas").map { _1.fetch("micro_area_id") }).to eq([ kept_area.id ])

    # O cursor do escopo novo segue sem reset.
    expect(wire(fetch(pages.last.fetch("next_cursor"), user: agent, on: agent_device))).to include("reset" => false)
  end

  it "who_to_visit só na última página" do
    household = registry_household!(micro_area: area)
    registration = registry_registration!(household: household)

    pages = all_pages(limit: 1)

    expect(pages.size).to eq(3)
    expect(pages[0..-2].map { _1.fetch("who_to_visit") }).to eq([ nil, nil ])
    who = pages.last.fetch("who_to_visit")
    expect(Time.iso8601(who.fetch("generated_at"))).to be_within(1.minute).of(Time.current)
    expect(who.fetch("micro_areas").map { _1.fetch("micro_area_id") }).to eq([ area.id ])
    person = who.dig("micro_areas", 0, "people").sole
    expect(person).to include("patient_id" => registration.patient_id, "micro_area" => { "id" => area.id, "code" => "01" })
    expect(person.fetch("reasons").map { _1.fetch("code") }).to include("never_visited")

    # A sincronização seguinte, sem mudança: página vazia e a lista completa de novo.
    empty = wire(fetch(pages.last.fetch("next_cursor")))
    expect(empty).to include("items" => [], "removals" => [], "has_more" => false, "reset" => false)
    expect(empty.dig("who_to_visit", "micro_areas", 0, "people").map { _1.fetch("patient_id") }).to eq([ registration.patient_id ])
  end

  it "trilha por página com exatamente os ids dela; página só de microáreas não grava" do
    household = registry_household!(micro_area: area)
    first = registry_registration!(household: household)
    registry_family!(household, responsible: first.patient)
    second = registry_registration!(household: household)
    base = 10.minutes.ago
    [ area, household, first.reload, second ].each_with_index { |record, index| record.update_columns(updated_at: base + index.seconds) }

    pages = all_pages(limit: 1)

    expect(pages.map { refs([ _1 ]) }).to eq([ [ [ "micro_area", area.id ] ], [ [ "household", household.id ] ],
                                              [ [ "registration", first.id ] ], [ [ "registration", second.id ] ] ])
    trail = field_trail
    expect(trail.size).to eq(3)
    expect(trail.map { _1.payload.slice("user_id", "field_device_id").values }.uniq).to eq([ [ acs.id, device.id ] ])
    expect(trail.map { _1.payload.fetch("household_ids") }).to eq([ [ household.id ], [], [] ])
    expect(trail[0].payload.fetch("patient_ids")).to eq([ first.patient_id ])
    expect(trail[1].payload.fetch("patient_ids")).to eq([ first.patient_id ])
    # Última página: o cadastro dela e as pessoas do who_to_visit.
    expect(trail[2].payload.fetch("patient_ids")).to contain_exactly(second.patient_id, first.patient_id)
  end

  it "paciente provisório da UPA nunca chega ao download (Q47)" do
    household = registry_household!(micro_area: area)
    known = registry_registration!(household: household)
    # Nenhum comando cadastra o provisório: as linhas direto (`over`).
    patient = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "homem idoso")
    provisional = registry_registration!(patient: patient, household: household, is_responsible: false)

    pages = all_pages

    ids = refs(pages).map(&:last)
    expect(ids).to include(known.id)
    expect(ids).not_to include(provisional.id)
    people = pages.last.dig("who_to_visit", "micro_areas", 0, "people").map { _1.fetch("patient_id") }
    expect(people).to eq([ known.patient_id ])
    expect(field_trail.flat_map { _1.payload.fetch("patient_ids") }).not_to include(provisional.patient_id)
  end

  it "o corte de agora − 2 s deixa para a próxima página o que acabou de mudar" do
    household = registry_household!(micro_area: area)
    page = wire(described_class.page(user: acs, device: device, cursor: nil, limit: 200, now: Time.current))
    expect(refs([ page ]).map(&:last)).not_to include(household.id)
    expect(refs(all_pages(page.fetch("next_cursor"))).map(&:last)).to include(household.id)
  end

  it "consultas por página não crescem com o número de itens" do
    seed = ->(count) { Array.new(count) { registry_registration!(household: registry_household!(micro_area: area)) } }
    count_queries = lambda do
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { fetch }
      statements.size
    end
    seed.call(1)
    fetch # aquece caches (catálogo da cidade, esquemas)
    few = count_queries.call
    seed.call(4)
    many = count_queries.call
    expect(many).to eq(few)
  end

  it "cursor adulterado ou de outra versão → FieldSync::Cursor::Invalid" do
    good = wire(fetch).fetch("next_cursor")
    decoded = JSON.parse(Base64.urlsafe_decode64(good))
    tampered = [ "nao-e-cursor", Base64.urlsafe_encode64("{}", padding: false),
                 Base64.urlsafe_encode64(decoded.merge("v" => 2).to_json, padding: false),
                 Base64.urlsafe_encode64(decoded.merge("after_id" => "x").to_json, padding: false),
                 Base64.urlsafe_encode64(decoded.merge("since" => "ontem").to_json, padding: false),
                 Base64.urlsafe_encode64(decoded.merge("extra" => 1).to_json, padding: false) ]
    tampered.each { |raw| expect { fetch(raw) }.to raise_error(FieldSync::Cursor::Invalid), raw }
  end

  describe FieldSync::Scope do
    it "ACS: as microáreas ativas em que é o responsável; digest só dos ids ordenados" do
      second = registry_micro_area!(code: "03", team: team, acs: acs)
      registry_micro_area!(code: "04", team: team, acs: acs).update!(active: false)
      scope = described_class.for(acs)
      expect(scope.fetch(:micro_area_ids)).to eq([ area.id, second.id ].sort)
      expect(scope.fetch(:digest)).to eq(Digest::SHA256.hexdigest([ area.id, second.id ].sort.join(",")))
    end

    it "outro CBO da Tabela 7: só as atribuições ativas" do
      agent = field_agent!(cbo: "322255", team: team)
      assigned = registry_micro_area!(code: "05", team: team)
      ended = registry_micro_area!(code: "06", team: team)
      assignment!(assigned, agent.professional, by: nurse)
      HomeVisits::EndAssignment.call(assignment: assignment!(ended, agent.professional, by: nurse), by: nurse)
      expect(described_class.for(agent).fetch(:micro_area_ids)).to eq([ assigned.id ])
    end
  end
end
