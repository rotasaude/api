require "rails_helper"

# Módulo 35a (contrato §7; Q16(c), Q20(1); W-13; plano, Review Focus 1): o
# substituto do imóvel fechado, recusado ou vago pelo caminho real da visita
# (HomeVisits::Record com o boletim). O vizinho anterior primeiro, depois o
# posterior, alternando para fora, só entre os não sorteados; um substituto só
# por item; sem candidato, o quarteirão fica com um a menos.
RSpec.describe VectorControl::Liraa::Items, type: :model do
  let!(:city) { vector_city! }
  let(:team) { registry_team! }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "1") }
  let!(:homes) { liraa_households!(block, 12, micro_area: area) }
  let(:order) { Household.where(id: homes.map(&:id)).order(:registered_at, :id).pluck(:id) }
  # N = 12, standard: n = 12, h = 3, b = 4, k = 1 → o quarteirão inteiro; imóveis 1, 6 e 11.
  let(:survey) do
    liraa_parameters!(liraa_standard_min: 10, liraa_standard_max: 100, liraa_half_min: 5)
    liraa_survey!([ { mode: "standard", blocks: [ block ] } ]).tap do |survey|
      VectorControl::Liraa::Draw.call(survey: survey, by: endemic_coordinator!, random: fixed_random(1))
    end
  end

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def items = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: survey.id })
  def drawn(position) = items.find_by!(position: position, substitute_of_id: nil)
  def substitute_of(item) = LiraaDrawItem.find_by(substitute_of_id: item.id)

  def visit(item, situation)
    @minute = (@minute || 40) - 1
    report = { "activity" => "liraa", "work_type" => "routine", "situation" => situation, "educational_action" => false,
               "liraa_draw_item_id" => item.id }
    params = { "client_uuid" => SecureRandom.uuid, "team_id" => team.id,
               "occurred_at" => [ @minute.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0).iso8601,
               "household_id" => item.household_id, "subject" => "none",
               "outcome" => VectorControl::Catalog::SITUATION_OUTCOME.fetch(situation), "reasons" => [], "shared" => false,
               "vector_inspection" => report }
    result = HomeVisits::Record.call(params: params, by: agent, vector_control: true)
    raise "visita recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:visit]
  end

  it "o sorteio deu 1, 6 e 11" do
    expect(items.order(:position).pluck(:position, :household_id)).to eq([ 1, 6, 11 ].map { |at| [ at, order[at - 1] ] })
  end

  it "fechado → substituted e o anterior nasce pending com substitute_of_id; recusado e vago também (Q20(1))" do
    closed = drawn(6)
    visit(closed, "closed")
    expect(closed.reload.status).to eq("substituted")
    expect(substitute_of(closed)).to have_attributes(household_id: order[4], position: 5, status: "pending", city_block_id: block.id,
                                                     liraa_stratum_id: closed.liraa_stratum_id, version: 1)

    vacant = drawn(11)
    visit(vacant, "vacant")
    expect(substitute_of(vacant)).to have_attributes(household_id: order[9], position: 10, status: "pending")

    refused = drawn(1)
    visit(refused, "refused")
    expect(substitute_of(refused)).to have_attributes(household_id: order[1], position: 2) # sem anterior: o posterior
  end

  it "alterna para fora e pula os já sorteados (Q16(c))" do
    first = drawn(1)
    visit(first, "refused")
    second = substitute_of(first) # o 2º
    visit(second, "closed")
    expect(substitute_of(second)).to have_attributes(household_id: order[2], position: 3) # o 1º já é item: o 3º

    middle = drawn(6)
    visit(middle, "closed")
    fifth = substitute_of(middle)
    expect(fifth.position).to eq(5)
    visit(fifth, "closed")
    expect(substitute_of(fifth)).to have_attributes(position: 4) # anterior do 5º
  end

  it "retirada da visita volta o item a pending; o substituto inspecionado fica; nova recusa não cria outro (Review Focus 1)" do
    item = drawn(6)
    refusal = visit(item, "refused")
    substitute = substitute_of(item)
    visit(substitute, "worked")
    expect(substitute.reload.status).to eq("inspected")

    expect(HomeVisits::Withdraw.call(refusal, by: agent, expected_state: "recorded", reason: "registrada no imóvel errado")).to be_ok
    expect(item.reload).to have_attributes(status: "pending")
    expect(substitute.reload).to have_attributes(status: "inspected")

    visit(item, "refused")
    expect(item.reload.status).to eq("substituted")
    expect(LiraaDrawItem.where(substitute_of_id: item.id).pluck(:id)).to eq([ substitute.id ])
  end

  it "substituição sem vizinho → quarteirão com um a menos, contado em missing" do
    small = city_block!(neighborhood: neighborhood, number: "2")
    liraa_households!(small, 2, micro_area: area)
    census = liraa_survey!([ { mode: "census", blocks: [ small ] } ]) # N = 2 < 5: todos sorteados
    expect(VectorControl::Liraa::Draw.call(survey: census, by: endemic_coordinator!)).to be_ok
    item = LiraaDrawItem.joins(:liraa_stratum).where(liraa_strata: { liraa_survey_id: census.id }).order(:position).first

    visit(item, "closed")

    expect(item.reload.status).to eq("substituted")
    expect(substitute_of(item)).to be_nil
    expect(VectorControl::Liraa::Index.for(census)[:strata].sole).to include(planned: 2, substitutions: 0, missing: 1)
  end

  it "levantamento que não está sorteado: nenhum substituto" do
    item = drawn(6)
    survey.update!(status: "closed", closed_at: Time.current)
    expect(described_class.substitute!(item)).to be_nil
    expect(substitute_of(item)).to be_nil
  end
end

# Review Focus 1 com threads reais (o molde do record_inspection_spec): duas
# recusas do mesmo item → um substituto só; duas recusas de itens vizinhos ao
# mesmo tempo → a segunda espera a trava do estrato e não escolhe o mesmo
# imóvel. Contra TEST_CITY_A, sem fixture transacional.
RSpec.describe VectorControl::Liraa::Items, "× substituições ao mesmo tempo" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def snapshot
    connection = ApplicationRecord.connection
    connection.tables.select { |table| connection.column_exists?(table, :id) }
              .to_h { |table| [ table, connection.select_values("SELECT id::text FROM #{connection.quote_table_name(table)}").to_set ] }
  end

  before do
    @before = in_city { snapshot }
    @ids = in_city do
      team = registry_team!
      agent = endemic_agent!(team: team)
      area = MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area
      other = field_agent!(cbo: TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO, team: team)
      assignment!(area, other.professional)
      neighborhood = Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual")
      block = city_block!(neighborhood: neighborhood, number: "7")
      homes = liraa_households!(block, 5, micro_area: area)
      order = Household.where(id: homes.map(&:id)).order(:registered_at, :id).pluck(:id)
      survey = LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: Time.zone.today, ends_on: Time.zone.today + 6)
      stratum = LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "standard")
      LiraaStratumBlock.create!(liraa_stratum: stratum, liraa_survey_id: survey.id, city_block: block, drawn: true, household_start: 1)
      first = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household_id: order[0], position: 1)
      third = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household_id: order[2], position: 3)
      survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 0)
      { agents: [ agent.id, other.id ], team: team.id, order: order, first: first.id, third: third.id }
    end
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        snapshot.each do |table, ids|
          fresh = ids - @before.fetch(table, Set.new)
          next if fresh.empty?

          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id::text IN (#{fresh.map { connection.quote(_1) }.join(',')})")
        end
      end
    end
  end

  def refuse_now(go, item_id, agent_id)
    go.pop(timeout: 5) or raise "timeout esperando go"
    in_city do
      item = LiraaDrawItem.find(item_id)
      report = { "activity" => "liraa", "work_type" => "routine", "situation" => "refused", "educational_action" => false,
                 "liraa_draw_item_id" => item.id }
      HomeVisits::Record.call(params: { "client_uuid" => SecureRandom.uuid, "team_id" => @ids[:team],
                                        "occurred_at" => Time.current.change(usec: 0).iso8601, "household_id" => item.household_id,
                                        "subject" => "none", "outcome" => 2, "reasons" => [], "vector_inspection" => report },
                              by: User.find(agent_id), vector_control: true)
    end
  rescue StandardError => e
    e
  end

  # A primeira grava e fica parada antes do commit (no home_visit.recorded,
  # depois do substituto); a segunda começa e espera numa trava.
  def race(first_args, second_args)
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "home_visit.recorded"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    go_first = Queue.new
    first_result = Queue.new
    threads << (holder = Thread.new { first_result << refuse_now(go_first, *first_args) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << refuse_now(go_second, *second_args) })
    go_second << true
    expect(wait_for_lock_wait).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
  end

  it "duas recusas do mesmo item em threads → um substituto só; a segunda liraa_item_not_found" do
    first, second = race([ @ids[:third], @ids[:agents][0] ], [ @ids[:third], @ids[:agents][1] ])

    expect([ first, second ]).to all(be_a(Result)) # nenhuma exceção (deadlock, trigger, único)
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :liraa_item_not_found, { path: "vector_inspection.liraa_draw_item_id" } ])
    in_city do
      expect(LiraaDrawItem.where(substitute_of_id: @ids[:third]).pluck(:household_id)).to eq([ @ids[:order][1] ])
    end
  end

  it "recusas de dois itens com o mesmo vizinho em threads → a segunda espera o estrato e escolhe outro imóvel" do
    first, second = race([ @ids[:first], @ids[:agents][0] ], [ @ids[:third], @ids[:agents][1] ])

    expect([ first, second ]).to all(be_a(Result))
    expect([ first, second ]).to all(be_ok)
    in_city do
      expect(LiraaDrawItem.where(substitute_of_id: @ids[:first]).pluck(:household_id)).to eq([ @ids[:order][1] ])
      expect(LiraaDrawItem.where(substitute_of_id: @ids[:third]).pluck(:household_id)).to eq([ @ids[:order][3] ])
    end
  end
end
