require "rails_helper"

# Módulo 35a, Task 13 (ADR 0054; contrato §10, §17; Q8): os sete relatórios
# na forma VectorReport ({ name, provisional?, columns, rows, notes? }), só
# contagens agregadas no banco, com consultas constantes; SmallCount 1–4 nos
# casos do `blocks`; filtro inválido → invalid_request com path; nunca
# pessoa.
RSpec.describe VectorControl::Reports, type: :model do
  let!(:city) { block_city! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:other) { Neighborhood.create!(name: "Batel #{SecureRandom.hex(3)}", source: "manual") }
  let(:cycle) { VectorCycle.create!(year: 2026, number: 10, starts_on: Date.new(2026, 10, 1), ends_on: Date.new(2026, 10, 31)) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def house!(type = "1", hood: neighborhood) = registry_household_rows!(area, neighborhood_id: hood.id, property_type: type)

  def sheet(on, who) = ((@sheets ||= {})[[ who.id, on ]] ||= home_visit_day!(agent: who, day: on))

  def inspect!(household, situation, on:, who: agent, minute: 0, **attrs)
    visit = home_visit!(day: sheet(on, who), micro_area: area, household: household,
                        occurred_at: on.in_time_zone.change(hour: 9) + minute.minutes,
                        outcome: VectorControl::Catalog::SITUATION_OUTCOME.fetch(situation))
    VectorInspection.create!(home_visit: visit, household: household, activity: "li", work_type: "routine", situation: situation,
                             educational_action: false, **attrs)
  end

  def measure!(inspection, product, charges, method: "focal")
    VectorInspectionMeasure.create!(vector_inspection: inspection, method: method, vector_product: product,
                                    charges: BigDecimal(charges), quantity: BigDecimal(charges) * product.charge_size)
  end

  def build(name, **filters)
    result = described_class.build(name, filters: filters.transform_keys(&:to_s))
    expect(result).to be_ok
    result.payload[:report]
  end

  def row(report, key, value) = report[:rows].find { |line| line[key] == value }

  it "situations: comércio (tipo 2) em C, abrigo (7) em R, escola (5) em O; pendência % com uma casa; cobertura por bairro" do
    on = Date.new(2026, 10, 5)
    inspect!(house!("1"), "worked", on: on)
    inspect!(house!("1"), "worked", on: on)
    inspect!(house!("7"), "closed", on: on)
    inspect!(house!("2"), "worked", on: on)
    inspect!(house!("5"), "refused", on: on)
    house!("1")
    inspect!(house!("2", hood: other), "vacant", on: on)

    report = build("situations", cycle_id: cycle.id, neighborhood_ids: [ neighborhood.id, other.id ])
    expect(report.keys).to eq(%i[name columns rows notes])
    expect(report[:name]).to eq("situations")
    expect(report[:columns].map { |column| column.values_at(:key, :kind) }).to include([ "label", "text" ], [ "visited", "count" ],
                                                                                         [ "pending_percent", "percent" ])
    expect(report[:rows].map { |line| line["label"] })
      .to eq([ "R (residencial)", "C (comércio)", "TB (terreno baldio)", "PE (ponto estratégico)", "O (outros)",
               neighborhood.name, other.name ])
    expect(row(report, "label", "R (residencial)")).to eq(
      "group" => "Classe de imóvel", "label" => "R (residencial)", "registered_households" => 4, "to_visit" => 4, "visited" => 3,
      "worked" => 2, "closed" => 1, "refused" => 0, "vacant" => 0, "recovered" => 0, "pending_percent" => "33.3",
      "coverage_percent" => "75.0"
    )
    expect(row(report, "label", "C (comércio)")).to include("visited" => 2, "worked" => 1, "vacant" => 1, "pending_percent" => "0.0")
    expect(row(report, "label", "O (outros)")).to include("visited" => 1, "refused" => 1, "pending_percent" => "100.0")
    expect(row(report, "label", "TB (terreno baldio)")).to include("visited" => 0, "pending_percent" => nil, "coverage_percent" => nil)
    expect(row(report, "label", neighborhood.name)).to include("group" => "Bairro", "registered_households" => 6, "to_visit" => 6,
                                                               "visited" => 5, "pending_percent" => "40.0", "coverage_percent" => "83.3")
    expect(row(report, "label", other.name)).to include("visited" => 1, "vacant" => 1, "coverage_percent" => "100.0")
    expect(report[:notes].first).to start_with("Cobertura do cadastro: contam só os 7 domicílios ativos")
  end

  it "strategic_points por quinzena da última visita" do
    first = house!("4")
    second = house!("4")
    house!("4")
    inspect!(first, "worked", on: Date.new(2026, 10, 3))
    inspect!(first, "closed", on: Date.new(2026, 10, 20))
    inspect!(second, "worked", on: Date.new(2026, 10, 5))
    inspect!(house!("1"), "worked", on: Date.new(2026, 10, 5))
    inspect!(house!("4"), "refused", on: Date.new(2026, 9, 30))

    report = build("strategic_points", cycle_id: cycle.id)
    none = { "worked" => nil, "closed" => nil, "refused" => nil, "vacant" => nil }
    expect(report[:rows]).to eq([
      { "period" => "01–15/10/2026", "strategic_points" => 1, "worked" => 1, "closed" => 0, "refused" => 0, "vacant" => 0 },
      { "period" => "16–31/10/2026", "strategic_points" => 1, "worked" => 0, "closed" => 1, "refused" => 0, "vacant" => 0 },
      { "period" => "Sem visita no ciclo", "strategic_points" => 2 }.merge(none),
      { "period" => "Total", "strategic_points" => 4, "worked" => 1, "closed" => 1, "refused" => 0, "vacant" => 0 }
    ])
  end

  it "production por agente e dia com cargas por produto" do
    colleague = endemic_agent!
    larvicide = vector_product!(code: "PYR", name: "Pyriproxyfen 0,5% G")
    adulticide = vector_product!(code: "MAL", name: "Malathion", unit: "ml", charge_size: "1.00", uses: %w[spatial])
    on = Date.new(2026, 10, 6)
    worked = inspect!(house!, "worked", on: on)
    VectorInspectionDeposit.create!(vector_inspection: worked, group: "A2", existing: 3, with_water: 3, with_larvae: 1, eliminated: 2, treated: 1)
    VectorInspectionDeposit.create!(vector_inspection: worked, group: "B", existing: 1, with_water: 1, with_larvae: 0, eliminated: 1, treated: 0)
    VectorSample.create!(vector_inspection_id: worked.id, number: 1, deposit_group: "A2", larvae_collected: 3,
                         label: "#{SecureRandom.hex(4).upcase}-01")
    measure!(worked, larvicide, "1.50")
    inspect!(house!, "closed", on: on, minute: 5)
    measure!(inspect!(house!, "worked", on: on + 1), larvicide, "2")
    measure!(inspect!(house!, "worked", on: on, who: colleague), adulticide, "3", method: "spatial")
    gone = inspect!(house!, "worked", on: on, minute: 9)
    measure!(gone, larvicide, "9")
    gone.home_visit.update!(withdrawn_at: Time.current, withdrawn_by_user: agent, withdrawal_reason: "registrada no imóvel errado")

    report = build("production", from: "2026-10-01", to: "2026-10-31")
    expect(report[:columns].last(2)).to eq([ { key: "charges_#{adulticide.id}", label: "Cargas — MAL", kind: "decimal" },
                                             { key: "charges_#{larvicide.id}", label: "Cargas — PYR", kind: "decimal" } ])
    name = agent.professional.professional_name
    expect(report[:rows].select { |line| line["professional"] == name }).to eq([
      { "professional" => name, "day" => "06/10/2026", "households" => 2, "worked" => 1, "eliminated" => 3, "treated" => 1,
        "samples" => 1, "charges_#{adulticide.id}" => "0.00", "charges_#{larvicide.id}" => "1.50" },
      { "professional" => name, "day" => "07/10/2026", "households" => 1, "worked" => 1, "eliminated" => 0, "treated" => 0,
        "samples" => 0, "charges_#{adulticide.id}" => "0.00", "charges_#{larvicide.id}" => "2.00" }
    ])

    filtered = build("production", from: "2026-10-01", to: "2026-10-31", professional_ids: [ colleague.professional.id ])
    expect(filtered[:rows]).to eq([ { "professional" => colleague.professional.professional_name, "day" => "06/10/2026",
                                      "households" => 1, "worked" => 1, "eliminated" => 0, "treated" => 0, "samples" => 0,
                                      "charges_#{adulticide.id}" => "3.00" } ])
  end

  it "consumption por produto com faltas por causa" do
    product = vector_product!(code: "PYR", name: "Pyriproxyfen 0,5% G")
    location = vector_location!
    vector_lot!(location, product: product, quantity: "10")
    vector_stock_location!(location)
    vector_visit!(product: product, charges: 2, agent: agent)   # baixa de 4.00
    vector_visit!(product: product, charges: 4, agent: agent)   # 8.00 > 6.00: falta por saldo
    vector_stock_location!(nil)
    vector_visit!(product: product, charges: 1, agent: agent)   # sem local
    expect(VectorStockShortfall.pluck(:cause)).to contain_exactly("insufficient_balance", "no_location")

    report = build("consumption", from: today.iso8601, to: today.iso8601)
    expect(report[:rows]).to eq([
      { "product" => "PYR — Pyriproxyfen 0,5% G", "unit" => "g", "charges" => "7.00", "quantity" => "14.00", "deducted" => "4.00",
        "shortfalls_no_location" => 1, "shortfalls_insufficient_balance" => 1, "shortfalls_no_lot" => 0 }
    ])
    expect(build("consumption", from: (today - 3).iso8601, to: (today - 1).iso8601)[:rows]).to eq([])
  end

  describe "blocks" do
    def cases!(block, count)
      Array.new(count) do
        notification = arbovirus_case!(patient: registry_patient!)
        TransmissionBlockCase.create!(transmission_block: block, disease_notification: notification, case_on: today, added_by: "job",
                                      number: (TransmissionBlockCase.maximum(:number) || 0) + 1)
        notification
      end
    end

    it "3 casos saem suprimidos; 5 saem 5; horas da notificação até a confirmação" do
      proposed = TransmissionBlock.create!(disease_group: "arbovirus")
      cases!(proposed, 3)
      active = TransmissionBlock.create!(disease_group: "arbovirus")
      notifications = cases!(active, 5)
      active.update!(status: "active", confirmed_by_user: endemic_coordinator!,
                     confirmed_at: DiseaseNotification.where(id: notifications.map(&:id)).minimum(:created_at) + 10.hours)
      TransmissionBlockCycle.create!(transmission_block: active, number: 1, starts_on: today, ends_on: today + 3)

      report = build("blocks", from: today.iso8601, to: today.iso8601)
      expect(report[:rows]).to eq([
        { "status" => "Proposto", "blocks" => 1, "cases" => Admin::SmallCount::SUPPRESSED, "hours_to_confirmation" => nil, "cycles" => 0 },
        { "status" => "Ativo", "blocks" => 1, "cases" => 5, "hours_to_confirmation" => "10.0", "cycles" => 1 },
        { "status" => "Encerrado", "blocks" => 0, "cases" => 0, "hours_to_confirmation" => nil, "cycles" => 0 },
        { "status" => "Descartado", "blocks" => 0, "cases" => 0, "hours_to_confirmation" => nil, "cycles" => 0 }
      ])
      expect(build("blocks", from: (today + 1).iso8601, to: (today + 2).iso8601)[:rows].sum { |line| line["blocks"] }).to eq(0)
    end
  end

  it "liraa: índices por estrato e município, provisório com amostra sem resultado, substituído sem candidato nas notas" do
    block = city_block!(neighborhood: neighborhood, number: "1")
    homes = liraa_households!(block, 2, micro_area: area)
    survey = LiraaSurvey.create!(name: "LIRAa outubro", starts_on: today, ends_on: today + 6)
    stratum = LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "standard")
    first = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: homes[0], position: 1)
    LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: homes[1], position: 2, status: "substituted")
    survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 0)
    inspection = inspect!(homes[0], "worked", on: today, liraa_draw_item_id: first.id)
    VectorSample.create!(vector_inspection_id: inspection.id, number: 1, deposit_group: "B", larvae_collected: 4,
                         label: "#{SecureRandom.hex(4).upcase}-01")

    report = build("liraa", survey_id: survey.id)
    expect(report.keys).to eq(%i[name provisional columns rows notes])
    expect(report[:provisional]).to be(true)
    expect(report[:rows].map { |line| line.values_at("stratum", "planned", "inspected", "missing", "iip", "iip_class") })
      .to eq([ [ "Estrato 1", 2, 1, 1, "0.0", "Satisfatório" ], [ "Município", 2, 1, 1, "0.0", "Satisfatório" ] ])
    expect(report[:notes]).to eq([ "Provisório: há amostra sem resultado de laboratório.", "1 imóvel(is) substituído(s) sem candidato." ])
  end

  it "filtro inválido → invalid_request com o path" do
    bad = lambda do |name, filters|
      result = described_class.build(name, filters: filters)
      [ result.reason, result.details[:path] ]
    end
    expect(bad.call("ovitraps", { "epi_weeks" => [ "2026-45", "2026-5" ] })).to eq([ :invalid_request, "epi_weeks[1]" ])
    expect(bad.call("ovitraps", { "epi_weeks" => "2026-45" })).to eq([ :invalid_request, "epi_weeks" ])
    expect(bad.call("ovitraps", { "epi_weeks" => [ "2026-45" ], "neighborhood_ids" => [ SecureRandom.uuid ] }))
      .to eq([ :invalid_request, "neighborhood_ids[0]" ])
    expect(bad.call("situations", {})).to eq([ :invalid_request, "cycle_id" ])
    expect(bad.call("situations", { "cycle_id" => SecureRandom.uuid })).to eq([ :invalid_request, "cycle_id" ])
    expect(bad.call("production", { "from" => "2026-10-01" })).to eq([ :invalid_request, "to" ])
    expect(bad.call("production", { "from" => "2026-02-30", "to" => "2026-03-01" })).to eq([ :invalid_request, "from" ])
    expect(bad.call("blocks", { "from" => "2026-10-02", "to" => "2026-10-01" })).to eq([ :invalid_request, "to" ])
    expect(bad.call("production", { "from" => "2026-10-01", "to" => "2026-10-02", "professional_ids" => [ "x" ] }))
      .to eq([ :invalid_request, "professional_ids[0]" ])
    expect(bad.call("liraa", { "survey_id" => "1" })).to eq([ :invalid_request, "survey_id" ])
  end

  it "nenhuma linha traz nome, CPF, CNS ou endereço" do
    on = Date.new(2026, 10, 5)
    home = house!("1")
    inspect!(home, "worked", on: on)
    patient = registry_patient!
    block = TransmissionBlock.create!(disease_group: "arbovirus")
    TransmissionBlockCase.create!(transmission_block: block, disease_notification: arbovirus_case!(patient: patient), case_on: today,
                                  added_by: "job", number: 1)
    survey = LiraaSurvey.create!(name: "LIRAa novembro", starts_on: today, ends_on: today + 6)
    LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "census")

    reports = [ build("situations", cycle_id: cycle.id), build("strategic_points", cycle_id: cycle.id),
                build("production", from: "2026-10-01", to: "2026-10-31"), build("consumption", from: "2026-10-01", to: today.iso8601),
                build("ovitraps", epi_weeks: [ "2026-41" ]), build("liraa", survey_id: survey.id),
                build("blocks", from: today.iso8601, to: today.iso8601) ]
    text = reports.to_json
    expect(reports.map { |report| report[:name] }).to eq(VectorControl::Catalog::REPORTS)
    [ patient.full_name, patient.cpf, "das Flores", "4133334444", patient.id, home.id ].each do |secret|
      expect(text).not_to include(secret)
    end
    expect(text).not_to include(agent.professional.cns)
  end

  # Consultas (sem SCHEMA/TRANSACTION/cache) de um build.
  def queries_of(name, **filters)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { build(name, **filters) }
    count
  end

  it "situations: consultas constantes, 1 ou N bairros e inspeções" do
    on = Date.new(2026, 10, 5)
    inspect!(house!("1"), "worked", on: on)
    cycle
    one = queries_of("situations", cycle_id: cycle.id, neighborhood_ids: [ neighborhood.id ])

    hoods = [ neighborhood, other, Neighborhood.create!(name: "Água Verde #{SecureRandom.hex(3)}", source: "manual") ]
    hoods.each_with_index do |hood, index|
      4.times { |n| inspect!(house!(%w[1 2 4 5][n], hood: hood), %w[worked closed refused vacant][n], on: on, minute: index * 10 + n) }
    end
    many = queries_of("situations", cycle_id: cycle.id, neighborhood_ids: hoods.map(&:id))
    expect(many).to eq(one)
  end

  it "ovitraps: consultas constantes, 1 ou N linhas" do
    week = Surveillance::EpiWeek.parse("2026-41")
    trap_in = lambda do |hood|
      block = city_block!(neighborhood: hood, number: SecureRandom.hex(2))
      Ovitrap.create!(number: "OV-#{SecureRandom.hex(3)}", household: ovitrap_household!(agent, block: block), city_block: block,
                      consent_at: Time.current, installed_on: week.starts_on, installed_by_user: agent, origin: "dashboard")
    end
    lab = vector_lab!
    read = lambda do |trap, eggs, installed_on|
      OvitrapReading.create!(ovitrap: trap, installed_on: installed_on, epi_week: VectorControl::OvitrapIndex.week_of(installed_on),
                             collected_on: installed_on + 5, condition: "ok", egg_count: eggs, counted_at: Time.current,
                             counted_by_user: lab)
    end
    read.call(trap_in.call(neighborhood), 3, week.starts_on + 1)
    one = queries_of("ovitraps", epi_weeks: [ "2026-41" ], neighborhood_ids: [ neighborhood.id ])

    hoods = [ neighborhood, other, Neighborhood.create!(name: "Rebouças #{SecureRandom.hex(3)}", source: "manual") ]
    hoods.each do |hood|
      trap = trap_in.call(hood)
      read.call(trap, 12, week.starts_on + 1)
      read.call(trap, 0, week.starts_on + 8)
    end
    many = queries_of("ovitraps", epi_weeks: [ "2026-41", "2026-42" ], neighborhood_ids: hoods.map(&:id))
    expect(many).to eq(one)
    report = build("ovitraps", epi_weeks: [ "2026-41", "2026-42" ], neighborhood_ids: hoods.map(&:id))
    expect(report[:rows].size).to eq(6)
    expect(report[:rows].first).to include("neighborhood" => neighborhood.name, "epi_week" => "2026-41", "examined" => 2,
                                           "positive" => 2, "eggs" => 15, "ipo" => "100.0", "ido" => "7.5", "idv" => "7.5")
  end
end
