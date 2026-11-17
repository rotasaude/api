require "rails_helper"

# Módulo 35a (ADR 0054; contrato §3, §9; Q7(3)(4)(7), Q9, Q10, Q13; plano,
# W-1, A-2, A-10): as regras puras do boletim. Um exemplo por regra, com a
# borda; o `path` de cada código é o da tabela da Task 2 do plano do dashboard
# (Q9), e só o primeiro erro sai (Q13).
RSpec.describe VectorControl::InspectionRules, type: :model do
  let(:day) { Date.new(2026, 11, 16) }
  let(:household) { { id: "6f0c1d2e-0000-4000-8000-000000000001", neighborhood_id: "nb-1" } }
  let(:profile) { { city_block_id: "cb-1" } }
  let(:product_id) { "9a9a9a9a-0000-4000-8000-000000000001" }
  let(:products) do
    { product_id => { active: true, uses: %w[focal perifocal], unit: "g", charge_size: BigDecimal("0.15") } }
  end

  def at(hour, min = 0, on: day) = on.in_time_zone.change(hour: hour, min: min)

  def facts(**over)
    described_class::Facts.new(**{ usable: true, cbo: "515140", outcome: 1, property_type: "1", occurred_at: at(10),
                                   profile_block_id: profile[:city_block_id], liraa_item: nil, transmission_block: nil,
                                   products: products, city_block: nil }.merge(over))
  end

  def input(**over)
    { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => true,
      "entered_at" => at(9, 40).iso8601, "left_at" => at(10, 20).iso8601,
      "deposits" => [ { "group" => "A2", "existing" => 3, "with_water" => 2, "with_larvae" => 2, "eliminated" => 1, "treated" => 1 } ],
      "measures" => [ { "method" => "focal", "vector_product_id" => product_id, "charges" => 2 } ],
      "samples" => [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 8 } ] }.merge(over.stringify_keys)
  end

  def check(value = input, visit: { "reasons" => [] }, household: self.household, profile: self.profile, **over)
    described_class.check(value, visit: visit, household: household, profile: profile, today: day, facts: facts(**over))
  end

  def first(...) = check(...).first
  def invalid(path) = { error: :vector_inspection_invalid, path: path }

  def deposit(group = "A1", **counts)
    { "group" => group, "existing" => 0, "with_water" => 0, "with_larvae" => 0, "eliminated" => 0, "treated" => 0 }
      .merge(counts.stringify_keys)
  end

  it "boletim completo do agente: nada a recusar" do
    expect(check).to eq([])
  end

  it "TACS 515130 → cbo_not_allowed path vector_inspection; gate inutilizável → feature_disabled" do
    expect(check(cbo: "515130")).to eq([ { error: :cbo_not_allowed, path: "vector_inspection" } ])
    expect(check(usable: false)).to eq([ { error: :feature_disabled, path: "vector_inspection" } ])
  end

  it "sem domicílio → vector_inspection_invalid path household_id (A-10), e só ele" do
    expect(check(input(situation: "closed"), household: nil, profile: nil)).to eq([ invalid("household_id") ])
  end

  it "sem work_type → vector_inspection_invalid path vector_inspection.work_type; sem deposits vale lista vazia (Q7(4))" do
    expect(first(input.except("work_type"))).to eq(invalid("vector_inspection.work_type"))
    expect(first(input.except("educational_action"))).to eq(invalid("vector_inspection.educational_action"))
    expect(check(input(educational_action: false).except("deposits", "measures", "samples", "entered_at", "left_at"))).to eq([])
    expect(first(input(extra: 1))).to eq(invalid("vector_inspection.extra"))
    expect(first(input(activity: "lirA"))).to eq(invalid("vector_inspection.activity"))
    expect(first(input(risk_class: "blue"))).to eq(invalid("vector_inspection.risk_class"))
    expect(first(input(deposits: {}))).to eq(invalid("vector_inspection.deposits"))
    expect(first(input(deposits: [ deposit.merge("odd" => 1) ]))).to eq(invalid("vector_inspection.deposits[0].odd"))
    expect(first(input(measures: [ { "method" => "nuke" } ]))).to eq(invalid("vector_inspection.measures[0].method"))
    expect(first(input(samples: [ { "number" => 1, "deposit_group" => "A2" } ]))).to eq(invalid("vector_inspection.samples[0].larvae_collected"))
    expect(first(nil)).to eq(invalid("vector_inspection"))
  end

  it "worked com outcome 2 → situation_outcome_mismatch path vector_inspection.situation; vacant ⇔ 3" do
    mismatch = { error: :situation_outcome_mismatch, path: "vector_inspection.situation" }
    expect(first(outcome: 2)).to eq(mismatch)
    expect(first(input(situation: "refused"))).to eq(mismatch)
    empty = input(educational_action: false, deposits: [], measures: [], samples: [])
    expect(check(empty.merge("situation" => "vacant"), outcome: 3)).to eq([])
    expect(first(empty.merge("situation" => "vacant"), outcome: 2)).to eq(mismatch)
    expect(check(empty.merge("situation" => "refused"), outcome: 2)).to eq([])
  end

  it "closed com depósito → inspection_not_worked path vector_inspection.deposits; só com ação educativa → path vector_inspection.educational_action" do
    expect(first(input(situation: "closed"), outcome: 3)).to eq(error: :inspection_not_worked, path: "vector_inspection.deposits")
    only_action = input(situation: "closed", deposits: [], measures: [], samples: [])
    expect(first(only_action, outcome: 3)).to eq(error: :inspection_not_worked, path: "vector_inspection.educational_action")
    expect(first(only_action.merge("measures" => [ { "method" => "mechanical" } ]), outcome: 3))
      .to eq(error: :inspection_not_worked, path: "vector_inspection.measures")
  end

  it "pe com tipo 1 → activity_property_mismatch path vector_inspection.activity; ie com 5 e 13 passa, com 4 recusa" do
    mismatch = { error: :activity_property_mismatch, path: "vector_inspection.activity" }
    expect(first(input(activity: "pe"))).to eq(mismatch)
    expect(check(input(activity: "pe"), property_type: "4")).to eq([])
    expect(check(input(activity: "ie"), property_type: "5")).to eq([])
    expect(check(input(activity: "ie"), property_type: "13")).to eq([])
    expect(first(input(activity: "ie"), property_type: "4")).to eq(mismatch)
    expect(check(input(activity: "li_t"), property_type: "99")).to eq([])
  end

  it "liraa sem item, com item de outro imóvel, item inspected ou levantamento closed → liraa_item_not_found" do
    item_id = "7b7b7b7b-0000-4000-8000-000000000001"
    item = { id: item_id, household_id: household[:id], status: "pending", survey_status: "drawn" }
    liraa = input(activity: "liraa", liraa_draw_item_id: item_id.upcase)
    not_found = { error: :liraa_item_not_found, path: "vector_inspection.liraa_draw_item_id" }
    expect(check(liraa, liraa_item: item)).to eq([])
    expect(first(input(activity: "liraa"))).to eq(not_found)
    expect(first(liraa)).to eq(not_found)
    expect(first(liraa, liraa_item: item.merge(household_id: SecureRandom.uuid))).to eq(not_found)
    expect(first(liraa, liraa_item: item.merge(status: "inspected"))).to eq(not_found)
    expect(first(liraa, liraa_item: item.merge(survey_status: "closed"))).to eq(not_found)
  end

  it "transmission_block proposto ou fora da área → transmission_block_not_active" do
    block_id = "8c8c8c8c-0000-4000-8000-000000000001"
    active = { id: block_id, status: "active", area_block_ids: [ "cb-1" ] }
    body = input(activity: "transmission_block", transmission_block_id: block_id)
    not_active = { error: :transmission_block_not_active, path: "vector_inspection.transmission_block_id" }
    expect(check(body, transmission_block: active)).to eq([])
    expect(first(body, transmission_block: active.merge(status: "proposed"))).to eq(not_active)
    expect(first(body, transmission_block: active.merge(area_block_ids: [ "cb-9" ]))).to eq(not_active)
    expect(first(body, profile: { city_block_id: nil }, transmission_block: active)).to eq(not_active)
    expect(first(body.except("transmission_block_id"), transmission_block: active)).to eq(not_active)
  end

  it "li com liraa_draw_item_id → vector_inspection_invalid path vector_inspection.liraa_draw_item_id" do
    expect(first(input(liraa_draw_item_id: SecureRandom.uuid))).to eq(invalid("vector_inspection.liraa_draw_item_id"))
    expect(first(input(transmission_block_id: SecureRandom.uuid))).to eq(invalid("vector_inspection.transmission_block_id"))
  end

  it "with_larvae 2 > with_water 1 → deposit_counts_inconsistent path vector_inspection.deposits[0].with_larvae; grupo repetido → path vector_inspection.deposits[1].group" do
    body = input(samples: [], deposits: [ deposit("A1", existing: 3, with_water: 1, with_larvae: 2) ])
    expect(first(body)).to eq(error: :deposit_counts_inconsistent, path: "vector_inspection.deposits[0].with_larvae")
    %w[with_water eliminated].each do |field|
      expect(first(input(samples: [], deposits: [ deposit("A1", existing: 1, field => 2) ])))
        .to eq(error: :deposit_counts_inconsistent, path: "vector_inspection.deposits[0].#{field}")
    end
    expect(first(input(samples: [], deposits: [ deposit("A1", existing: 2, with_water: 1, treated: 2) ])))
      .to eq(error: :deposit_counts_inconsistent, path: "vector_inspection.deposits[0].treated")
    expect(first(input(samples: [], deposits: [ deposit("A1"), deposit("A1") ])))
      .to eq(error: :deposit_counts_inconsistent, path: "vector_inspection.deposits[1].group")
    eight = (VectorControl::Catalog::DEPOSIT_GROUPS + [ "A1" ]).map { |group| deposit(group) }
    expect(first(input(samples: [], deposits: eight))).to eq(invalid("vector_inspection.deposits"))
  end

  it "existentes 1000 → vector_inspection_invalid path vector_inspection.deposits[0].existing; 999 passa; não inteira recusa" do
    expect(first(input(samples: [], deposits: [ deposit("B", existing: 1000) ]))).to eq(invalid("vector_inspection.deposits[0].existing"))
    expect(check(input(samples: [], deposits: [ deposit("B", existing: 999) ]))).to eq([])
    expect(first(input(samples: [], deposits: [ deposit("B", existing: 1.5) ]))).to eq(invalid("vector_inspection.deposits[0].existing"))
    expect(first(input(samples: [], deposits: [ deposit("B", treated: -1) ]))).to eq(invalid("vector_inspection.deposits[0].treated"))
  end

  it "focal sem produto, produto inativo ou sem `focal` em uses → product_not_allowed; mecânico com produto ou cargas; faixa das cargas; 21 medidas" do
    not_allowed = { error: :product_not_allowed, path: "vector_inspection.measures[0].vector_product_id" }
    focal = ->(**over) { input(measures: [ { "method" => "focal", "vector_product_id" => product_id, "charges" => 2 }.merge(over.stringify_keys) ]) }
    expect(first(input(measures: [ { "method" => "focal", "charges" => 2 } ]))).to eq(not_allowed)
    expect(first(focal.call, products: { product_id => products[product_id].merge(active: false) })).to eq(not_allowed)
    expect(first(focal.call, products: { product_id => products[product_id].merge(uses: %w[spatial]) })).to eq(not_allowed)
    expect(first(input(measures: [ { "method" => "spatial", "vector_product_id" => product_id, "charges" => 1 } ]))).to eq(not_allowed)

    expect(first(input(measures: [ { "method" => "mechanical", "vector_product_id" => product_id } ])))
      .to eq(invalid("vector_inspection.measures[0].vector_product_id"))
    expect(first(input(measures: [ { "method" => "mechanical", "charges" => 1 } ]))).to eq(invalid("vector_inspection.measures[0].charges"))
    [ 0, 999.01, 1.005, "2", nil ].each do |charges|
      expect(first(focal.call(charges: charges))).to eq(invalid("vector_inspection.measures[0].charges"))
    end
    expect(first(input(measures: [ { "method" => "focal", "vector_product_id" => product_id } ])))
      .to eq(invalid("vector_inspection.measures[0].charges"))
    expect(check(focal.call(charges: 999))).to eq([])
    expect(check(focal.call(charges: 0.01))).to eq([])

    twice = [ { "method" => "focal", "vector_product_id" => product_id, "charges" => 1 },
              { "method" => "focal", "vector_product_id" => product_id.upcase, "charges" => 2 } ]
    expect(first(input(measures: twice))).to eq(invalid("vector_inspection.measures[1]"))
    expect(first(input(measures: Array.new(21) { { "method" => "mechanical" } }))).to eq(invalid("vector_inspection.measures"))
    expect(check(input(measures: [ { "method" => "mechanical" } ]))).to eq([])
  end

  it "amostras 1 e 3 → samples_exceed_larvae path vector_inspection.samples[1]; 3 amostras com with_larvae 2; grupo sem larva; 11 larvas" do
    one = { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 8 }
    exceed = ->(index) { { error: :samples_exceed_larvae, path: "vector_inspection.samples[#{index}]" } }
    expect(check(input(samples: [ one, one.merge("number" => 2) ]))).to eq([])
    expect(first(input(samples: [ one, one.merge("number" => 3) ]))).to eq(exceed.call(1))
    expect(first(input(samples: [ one.merge("number" => 2) ]))).to eq(exceed.call(0))
    expect(first(input(samples: [ one, one.merge("number" => 2), one.merge("number" => 3) ]))).to eq(exceed.call(2))
    expect(first(input(samples: [ one.merge("deposit_group" => "B") ]))).to eq(exceed.call(0))
    expect(first(input(samples: [ one.merge("larvae_collected" => 11) ]))).to eq(invalid("vector_inspection.samples[0].larvae_collected"))
    expect(first(input(samples: [ one.merge("larvae_collected" => 0) ]))).to eq(invalid("vector_inspection.samples[0].larvae_collected"))
    many = Array.new(100) { |i| one.merge("number" => i + 1) }
    expect(first(input(samples: many))).to eq(invalid("vector_inspection.samples"))
  end

  it "saída − entrada = 12 h passa, 12 h 1 min recusa; só entered_at; entrada depois da visita; entrada no dia anterior → inspection_times_invalid path vector_inspection.entered_at" do
    bad = { error: :inspection_times_invalid, path: "vector_inspection.entered_at" }
    times = ->(entered, left) { input(entered_at: entered&.iso8601, left_at: left&.iso8601).compact }
    expect(check(times.call(at(0), at(12)))).to eq([])
    expect(first(times.call(at(0), at(12, 1)))).to eq(bad)
    expect(first(times.call(at(9, 40), nil))).to eq(bad)
    expect(first(times.call(nil, at(10, 20)))).to eq(bad)
    expect(first(times.call(at(10, 5), at(10, 20)))).to eq(bad)
    expect(first(times.call(at(9), at(9, 50)))).to eq(bad)
    expect(first(times.call(at(23, 50, on: day - 1), at(10, 20)))).to eq(bad)
    expect(check(times.call(nil, nil))).to eq([])
    expect(first(input(entered_at: "ontem"))).to eq(invalid("vector_inspection.entered_at"))
  end

  it "34–37 no corpo com boletim → reason_derived path reasons" do
    expect(first(visit: { "reasons" => [ 1, 35 ] })).to eq(error: :reason_derived, path: "reasons")
    expect(check(visit: { "reasons" => [ 1, 27 ] })).to eq([])
  end

  it "city_block_id com perfil já atribuído → block_already_set path vector_inspection.city_block_id; quarteirão de outro bairro ou sem bairro no mesmo path" do
    path = "vector_inspection.city_block_id"
    block_id = "5d5d5d5d-0000-4000-8000-000000000001"
    block = { id: block_id, neighborhood_id: "nb-1", active: true }
    body = input(city_block_id: block_id)
    expect(first(body, city_block: block)).to eq(error: :block_already_set, path: path)
    no_block = { profile: { city_block_id: nil }, profile_block_id: nil }
    expect(check(body, city_block: block, **no_block)).to eq([])
    expect(first(body, city_block: block.merge(neighborhood_id: "nb-2"), **no_block))
      .to eq(error: :block_not_in_household_neighborhood, path: path)
    expect(first(body, household: household.merge(neighborhood_id: nil), city_block: block, **no_block))
      .to eq(error: :household_without_neighborhood, path: path)
    expect(first(body, city_block: block.merge(active: false), **no_block)).to eq(invalid(path))
    expect(first(body, **no_block)).to eq(invalid(path))
  end

  it "primeiro erro = o do dashboard (Q13): situação errada e depósito incoerente → situation_outcome_mismatch" do
    body = input(deposits: [ deposit("A2", existing: 1, with_water: 2) ], samples: [])
    expect(check(body, outcome: 2)).to eq([ { error: :situation_outcome_mismatch, path: "vector_inspection.situation" } ])
  end

  it "derived_reasons: ação educativa + larva + mecânico + focal → [34, 35, 36, 37]; com [1] no corpo → [1, 34, 35, 36, 37]" do
    full = input(measures: [ { "method" => "mechanical" }, { "method" => "focal", "vector_product_id" => product_id, "charges" => 1 } ])
    expect(described_class.derived_reasons([], full)).to eq([ 34, 35, 36, 37 ])
    expect(described_class.derived_reasons(nil, full)).to eq([ 34, 35, 36, 37 ])
    expect(described_class.derived_reasons([ 1 ], full)).to eq([ 1, 34, 35, 36, 37 ])
    expect(described_class.derived_reasons([ 27, 1 ], input(educational_action: false, deposits: [], measures: [ { "method" => "mechanical" } ])))
      .to eq([ 1, 27, 36 ])
    closed = input(situation: "closed", educational_action: false, deposits: [], measures: [], samples: [])
    expect(described_class.derived_reasons([], closed)).to eq([])
    expect(described_class.derived_reasons("x", full)).to eq("x")
  end

  it "quantity(1.25, 0.15) = 0.19; quantity(0.01, 0.01) = 0.01 (teto em 2 casas, A-2)" do
    expect(described_class.quantity(1.25, BigDecimal("0.15"))).to eq(BigDecimal("0.19"))
    expect(described_class.quantity(0.01, BigDecimal("0.01"))).to eq(BigDecimal("0.01"))
    expect(described_class.quantity(2, BigDecimal("2.00"))).to eq(BigDecimal("4"))
  end

  it "label('3f2a9c1e-…', 4) = '3F2A9C1E-04'" do
    expect(described_class.label("3f2a9c1e-0b4d-4c1a-9e7f-1a2b3c4d5e6f", 4)).to eq("3F2A9C1E-04")
    expect(described_class.label("3f2a9c1e-0b4d-4c1a-9e7f-1a2b3c4d5e6f", 12)).to eq("3F2A9C1E-12")
  end

  it "Facts não mostra dado no inspect" do
    expect(facts.inspect).to eq("#<VectorControl::InspectionRules::Facts>")
  end
end
