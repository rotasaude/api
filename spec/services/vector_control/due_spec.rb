require "rails_helper"

# Módulo 35a (contrato §5; Q8, Q11): "Imóveis a visitar" do agente de
# endemias. Um motivo e um vínculo por imóvel ativo (transmission_block, liraa,
# pending, due, nesta ordem), due_since = last_worked_on + dias da cadência
# (nulo = nunca trabalhado, primeiro dentro do motivo), nunca morador.
RSpec.describe VectorControl::Due, type: :model do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:area) { MicroAreaFieldAssignment.active.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "7") }
  let(:today) { Time.zone.today }

  def household!(property_type: "1")
    registry_household_rows!(area, neighborhood_id: neighborhood.id, property_type: property_type)
  end

  # Perfil com o último trabalho direto na linha.
  def worked!(household, days_ago:, situation: "worked", block: nil, risk: nil)
    vector_profile!(household, block: block, risk: risk).tap do |profile|
      profile.update_columns(last_worked_on: days_ago && today - days_ago, last_situation: situation)
    end
  end

  def page(limit: 50, before: nil, user: agent)
    described_class.page(user: user, team: area.team, micro_area: area, before: before, limit: limit, today: today)
  end

  def items(**opts) = page(**opts).payload[:items]

  def active_block!(*city_blocks)
    TransmissionBlock.create!(disease_group: "arbovirus", status: "active", confirmed_at: Time.current,
                              confirmed_by_user: endemic_coordinator!, center_block: city_blocks.first).tap do |transmission|
      city_blocks.each { |city_block| TransmissionBlockArea.create!(transmission_block: transmission, city_block: city_block) }
    end
  end

  def pending_item!(household, block: self.block, status: "drawn")
    survey = LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: today, ends_on: today + 6)
    stratum = LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "census")
    item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1)
    survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 1) if status == "drawn"
    item
  end

  def deep_keys(value)
    case value
    when Hash then value.keys.map(&:to_s) + value.values.flat_map { |inner| deep_keys(inner) }
    when Array then value.flat_map { |inner| deep_keys(inner) }
    else []
    end
  end

  it "trabalhado há 60 dias com cadência 60 → due hoje; há 59 → fora" do
    due = household!.tap { |household| worked!(household, days_ago: 60) }
    worked!(household!, days_ago: 59)

    expect(items).to eq([ { household_id: due.id, address_short: "Rua das Flores, 120", property_type: "1", block: nil, risk_class: nil,
                            last_worked_on: (today - 60).iso8601, due_since: today.iso8601, reason: "due",
                            liraa_draw_item_id: nil, transmission_block_id: nil } ])
  end

  it "a cadência vem da tabela: (bairro, red) 30 vence antes do padrão" do
    VectorCadence.create!(neighborhood: neighborhood, risk_class: "red", days: 30)
    red = household!.tap { |household| worked!(household, days_ago: 30, risk: "red") }
    worked!(household!, days_ago: 30, risk: "green")
    pe = household!(property_type: "4").tap { |household| worked!(household, days_ago: 15) }

    expect(items.map { |item| [ item[:household_id], item[:due_since] ] })
      .to contain_exactly([ red.id, today.iso8601 ], [ pe.id, today.iso8601 ])
  end

  it "nunca trabalhado → due com due_since nil (com ou sem perfil)" do
    bare = household!
    profiled = household!.tap { |household| vector_profile!(household, block: block, risk: "yellow") }

    rows = items.index_by { |item| item[:household_id] }
    expect(rows.keys).to contain_exactly(bare.id, profiled.id)
    expect(rows[bare.id]).to include(reason: "due", due_since: nil, last_worked_on: nil, block: nil)
    expect(rows[profiled.id]).to include(reason: "due", due_since: nil, block: { id: block.id, number: "7" }, risk_class: "yellow")
  end

  it "fechado ontem → pending, não due" do
    closed = household!.tap { |household| worked!(household, days_ago: 10, situation: "closed") }
    refused = household!.tap { |household| worked!(household, days_ago: nil, situation: "refused") }

    expect(items.map { |item| [ item[:household_id], item[:reason], item[:due_since] ] })
      .to eq([ [ refused.id, "pending", nil ], [ closed.id, "pending", (today + 50).iso8601 ] ])
  end

  it "imóvel com item pending e no bloqueio → um item só, motivo transmission_block, com `transmission_block_id` e `liraa_draw_item_id: null`" do
    household = household!.tap { |row| worked!(row, days_ago: 1, block: block) }
    pending_item!(household)
    transmission = active_block!(block)

    expect(items).to eq([ { household_id: household.id, address_short: "Rua das Flores, 120", property_type: "1",
                            block: { id: block.id, number: "7" }, risk_class: nil, last_worked_on: (today - 1).iso8601,
                            due_since: (today + 59).iso8601, reason: "transmission_block", liraa_draw_item_id: nil,
                            transmission_block_id: transmission.id } ])
  end

  it "ordem: transmission_block, liraa, pending, due; dentro do motivo, due_since nulo primeiro (Q8)" do
    other_block = city_block!(neighborhood: neighborhood, number: "8")
    active_block!(other_block)
    in_block = household!.tap { |row| worked!(row, days_ago: 5, block: other_block) }
    liraa = household!.tap { |row| worked!(row, days_ago: 3, block: block) }
    item = pending_item!(liraa)
    pending = household!.tap { |row| worked!(row, days_ago: 2, situation: "refused") }
    overdue = household!.tap { |row| worked!(row, days_ago: 90) }
    never = household!
    draft_only = household!.tap { |row| worked!(row, days_ago: 1, block: block) }
    pending_item!(draft_only, status: "draft")

    rows = items
    expect(rows.map { |row| row[:household_id] }).to eq([ in_block.id, liraa.id, pending.id, never.id, overdue.id ])
    expect(rows.map { |row| row[:reason] }).to eq(%w[transmission_block liraa pending due due])
    expect(rows[1]).to include(liraa_draw_item_id: item.id, transmission_block_id: nil)
  end

  it "bloqueio proposto ou encerrado não conta" do
    household = household!.tap { |row| worked!(row, days_ago: 1, block: block) }
    TransmissionBlock.create!(disease_group: "arbovirus", status: "proposed").tap do |proposed|
      TransmissionBlockArea.create!(transmission_block: proposed, city_block: block)
    end
    expect(items.map { |item| item[:household_id] }).not_to include(household.id)
  end

  it "imóvel inativo fora" do
    household!.update_columns(status: "inactive")
    kept = household!
    expect(items.map { |item| item[:household_id] }).to eq([ kept.id ])
  end

  it "página com next_before; o cursor continua da chave, e cursor adulterado → invalid_cursor" do
    ids = Array.new(3) { household!.id }.sort
    first = page(limit: 2)
    expect(first.payload[:items].map { |item| item[:household_id] }).to eq(ids.first(2))
    expect(first.payload[:next_before]).to be_present
    second = page(limit: 2, before: first.payload[:next_before])
    expect(second.payload).to eq(items: [ items.last ], next_before: nil)
    expect(page(before: "lixo").reason).to eq(:invalid_cursor)
    expect(page(before: Base64.urlsafe_encode64("due:9::#{ids.first}", padding: false)).reason).to eq(:invalid_cursor)
  end

  it "ACS da microárea → cbo_not_allowed; agente em outra microárea → out_of_scope" do
    expect(page(user: registry_acs_of(area)).reason).to eq(:cbo_not_allowed)
    other = endemic_agent!(team: area.team)
    expect(page(user: other).reason).to eq(:out_of_scope)
    expect(page(user: endemic_agent!).reason).to eq(:out_of_scope)
  end

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end

  it "consultas constantes: 1 ou 8 imóveis na microárea, o mesmo número de consultas" do
    VectorCadence.create!(neighborhood: neighborhood, risk_class: "red", days: 30)
    active_block!(block)
    household!.tap { |row| worked!(row, days_ago: 90, block: block) }
    agent && area
    one = count_queries { page }

    other_block = city_block!(neighborhood: neighborhood, number: "9")
    7.times do |index|
      household = household!
      worked!(household, days_ago: 40 + index, block: other_block, risk: "red", situation: index.even? ? "worked" : "closed")
      pending_item!(household, block: other_block) if index < 3
    end
    expect(count_queries { page }).to eq(one)
    expect(items.size).to eq(8)
  end

  it "nenhum campo de morador nas chaves" do
    household = household!.tap { |row| worked!(row, days_ago: 70, block: block, risk: "red") }
    pending_item!(household)
    household!
    keys = deep_keys(page.payload)
    expect(keys).not_to include("patient", "patient_id", "name", "cpf", "cns", "phone", "contact_phone", "address")
    expect(keys.uniq).to match_array(%w[items next_before household_id address_short property_type block id number risk_class
                                        last_worked_on due_since reason liraa_draw_item_id transmission_block_id])
  end
end
