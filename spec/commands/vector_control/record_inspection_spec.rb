require "rails_helper"

# Módulo 35a (ADR 0054; contrato §3, §7, §9; Q7(1); plano, W-5, W-13, Review
# Focus 1 e 4): o boletim gravado pela visita (HomeVisits::Record com
# `vector_control: true`) e desfeito pela retirada (HomeVisits::Withdraw). A
# inspeção congela o quarteirão do perfil; `recovered` só na pendência
# trabalhada depois de fechada ou recusada; o perfil leva o último trabalho e
# volta à inspeção válida anterior na retirada; o item do LIRAa vira
# inspected/substituted e volta a pending; a colisão da etiqueta recusa a
# visita inteira.
RSpec.describe VectorControl::RecordInspection, type: :model do
  let!(:city) { vector_city! }
  let(:team) { registry_team! }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:household) { registry_household!(micro_area: area, neighborhood_id: neighborhood.id) }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def ago(minutes) = [ minutes.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0)

  def worked_report(**over)
    { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
      "deposits" => [ { "group" => "A2", "existing" => 2, "with_water" => 1, "with_larvae" => 1, "eliminated" => 0, "treated" => 0 } ],
      "samples" => [ { "number" => 1, "deposit_group" => "A2", "larvae_collected" => 5 } ] }.merge(over.stringify_keys)
  end

  def empty_report(situation, **over)
    { "activity" => "li", "work_type" => "routine", "situation" => situation, "educational_action" => false }.merge(over.stringify_keys)
  end

  def record(report, at: ago(5), home: household, uuid: SecureRandom.uuid, by: agent, vector_control: true, **over)
    params = { "client_uuid" => uuid, "team_id" => team.id, "occurred_at" => at.iso8601, "household_id" => home.id,
               "subject" => "none", "outcome" => VectorControl::Catalog::SITUATION_OUTCOME.fetch(report["situation"]), "reasons" => [], "shared" => false,
               "vector_inspection" => report }.merge(over.stringify_keys)
    HomeVisits::Record.call(params: params, by: by, vector_control: vector_control)
  end

  def record!(report, **opts)
    result = record(report, **opts)
    raise "visita recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:visit]
  end

  def inspection_of(visit) = VectorInspection.find_by!(home_visit_id: visit.id)
  def profile = HouseholdVectorProfile.find_by!(household_id: household.id)
  def withdraw(visit) = HomeVisits::Withdraw.call(visit, by: agent, expected_state: "recorded", reason: "registrada no imóvel errado")

  it "recovered só na pendência trabalhada depois de fechada" do
    closed = record!(empty_report("closed"), at: ago(30))
    recovered = record!(worked_report(work_type: "pending"), at: ago(20))
    again = record!(worked_report(work_type: "pending"), at: ago(10))
    expect([ closed, recovered, again ].map { |visit| inspection_of(visit).recovered }).to eq([ false, true, false ])

    other = registry_household!(micro_area: area, neighborhood_id: neighborhood.id)
    record!(empty_report("refused"), at: ago(30), home: other)
    routine = record!(worked_report, at: ago(20), home: other)
    expect(inspection_of(routine).recovered).to be(false)
  end

  it "duas visitas com client_uuid de mesmo prefixo de 8 caracteres e amostra 1 → a segunda recusada com sample_label_taken path vector_inspection.samples[0], nada gravado (Q7(1))" do
    first = record!(worked_report, uuid: "3f2a9c1e-#{SecureRandom.uuid[9..]}")
    expect(VectorSample.sole).to have_attributes(label: "3F2A9C1E-01", number: 1, deposit_group: "A2", larvae_collected: 5)
    counts = -> { [ HomeVisit.count, VectorInspection.count, VectorInspectionDeposit.count, VectorSample.count, profile.version ] }
    before = counts.call
    events = DomainEvent.count

    result = record(worked_report, uuid: "3F2A9C1E-#{SecureRandom.uuid[9..]}")
    expect([ result.reason, result.details ]).to eq([ :sample_label_taken, { path: "vector_inspection.samples[0]" } ])
    expect(counts.call).to eq(before)
    expect(DomainEvent.count).to eq(events)
    expect(profile.last_inspection_id).to eq(inspection_of(first).id)
  end

  it "perfil denormalizado (quarteirão e risco pelo boletim, último trabalho); retirada volta o perfil à anterior" do
    worked = record!(worked_report(city_block_id: block.id, risk_class: "red"), at: ago(30))
    first = inspection_of(worked)
    expect(first.city_block_id).to eq(block.id)
    expect(profile).to have_attributes(city_block_id: block.id, risk_class: "red", risk_assessed_on: today, last_inspection_id: first.id,
                                       last_situation: "worked", last_worked_on: today, updated_by_user_id: agent.id)
    version = profile.version

    closed = record!(empty_report("closed"), at: ago(10))
    second = inspection_of(closed)
    expect(second.city_block_id).to eq(block.id) # congelado do perfil
    expect(profile).to have_attributes(last_inspection_id: second.id, last_situation: "closed", last_worked_on: today,
                                       version: version + 1)
    expect(record(empty_report("closed", city_block_id: block.id), at: ago(5)).details).to eq(path: "vector_inspection.city_block_id")

    events = DomainEvent.where(name: "household_vector_profile.changed")
    expect { expect(withdraw(closed)).to be_ok }.to change(events, :count).by(1)
    expect(profile).to have_attributes(last_inspection_id: first.id, last_situation: "worked", last_worked_on: today,
                                       city_block_id: block.id, risk_class: "red", version: version + 2)
    expect(events.order(:occurred_at).last.payload).to eq("household_id" => household.id, "user_id" => agent.id)
    expect(VectorInspection.where(id: second.id)).to exist # a inspeção fica (só acréscimo)

    expect(withdraw(worked)).to be_ok
    expect(profile).to have_attributes(last_inspection_id: nil, last_situation: nil, last_worked_on: nil, city_block_id: block.id)
  end

  it "LIRAa: worked → inspected, closed → substituted; a retirada devolve a pending uma vez; de novo → visit_changed" do
    survey = LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: today, ends_on: today + 6)
    stratum = LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "census")
    item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1)
    other_home = registry_household!(micro_area: area, neighborhood_id: neighborhood.id)
    closed_item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: other_home, position: 2)
    survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 1)

    visit = record!(worked_report(activity: "liraa", liraa_draw_item_id: item.id))
    expect(item.reload).to have_attributes(status: "inspected", version: 2)
    expect(inspection_of(visit).liraa_draw_item_id).to eq(item.id)
    again = record(worked_report(activity: "liraa", liraa_draw_item_id: item.id), at: ago(4))
    expect([ again.reason, again.details ]).to eq([ :liraa_item_not_found, { path: "vector_inspection.liraa_draw_item_id" } ])

    record!(empty_report("closed", activity: "liraa", liraa_draw_item_id: closed_item.id), home: other_home)
    expect(closed_item.reload.status).to eq("substituted")

    expect(withdraw(visit)).to be_ok
    expect(item.reload).to have_attributes(status: "pending", version: 3)
    expect(withdraw(visit.reload).reason).to eq(:visit_changed)
    expect(item.reload.version).to eq(3)
  end

  describe "LIRAa: item e retirada" do
    let(:survey) { LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: today, ends_on: today + 6) }
    let(:stratum) { LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "census") }
    let!(:item) { LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1) }

    before { survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 1) }

    it "Q20(1): vacant → substituted, como closed e refused; a retirada do vacant devolve a pending" do
      visit = record!(empty_report("vacant", activity: "liraa", liraa_draw_item_id: item.id))
      expect(item.reload).to have_attributes(status: "substituted", version: 2)
      expect(LiraaDrawItem.where(substitute_of_id: item.id)).to be_empty # o substituto nasce na Task 10

      expect(withdraw(visit)).to be_ok
      expect(item.reload).to have_attributes(status: "pending", version: 3)
    end

    it "outra inspeção válida que mudou o item o mantém inspected na retirada" do
      visit = record!(worked_report(activity: "liraa", liraa_draw_item_id: item.id))
      expect(item.reload.status).to eq("inspected")
      VectorInspection.create!(home_visit: home_visit!(household: household, micro_area: area), household_id: household.id,
                               activity: "liraa", work_type: "routine", situation: "worked", educational_action: false,
                               liraa_draw_item_id: item.id)

      expect(withdraw(visit)).to be_ok
      expect(item.reload).to have_attributes(status: "inspected", version: 2)
    end
  end

  it "Q20(2): retirar o boletim que pôs quarteirão e risco deixa os dois no perfil e recalcula last_*" do
    closed = record!(empty_report("closed"), at: ago(30))
    worked = record!(worked_report(city_block_id: block.id, risk_class: "yellow"), at: ago(10))
    expect(profile).to have_attributes(city_block_id: block.id, risk_class: "yellow", last_inspection_id: inspection_of(worked).id)

    expect(withdraw(worked)).to be_ok
    expect(profile).to have_attributes(city_block_id: block.id, risk_class: "yellow", risk_assessed_on: today,
                                       last_inspection_id: inspection_of(closed).id, last_situation: "closed", last_worked_on: nil)
  end

  it "lugar e escopo antes do boletim: domicílio de outra microárea com micro_area_id → invalid_home_visit, sem perfil criado" do
    outside = registry_household!(micro_area: registry_micro_area!(code: "03", team: team), neighborhood_id: neighborhood.id)
    result = record(worked_report(activity: "liraa", liraa_draw_item_id: SecureRandom.uuid), home: outside, micro_area_id: area.id)
    expect([ result.reason, result.details ]).to eq([ :invalid_home_visit, { path: "micro_area_id" } ])
    expect(HouseholdVectorProfile.where(household_id: outside.id)).to be_empty
  end

  it "gate fora de uso ou outro CBO: recusa sem travar nem criar perfil" do
    expect(VectorControl::SaveProfile).not_to receive(:lock_profiles!)
    off = record(worked_report, vector_control: false)
    expect([ off.reason, off.details ]).to eq([ :feature_disabled, { path: "vector_inspection" } ])

    tacs = field_agent!(cbo: "322255", team: team)
    assignment!(area, tacs.professional)
    other = record(worked_report, by: tacs)
    expect([ other.reason, other.details ]).to eq([ :cbo_not_allowed, { path: "vector_inspection" } ])
    expect(HouseholdVectorProfile.count).to eq(0)
  end
end

# Review Focus 1 (plano; contrato §7): duas visitas ao mesmo item pending do
# LIRAa ao mesmo tempo. A primeira grava e fica parada antes do commit; a
# segunda espera na trava (perfil → item, depois do domicílio) e, solta, vê o
# item já inspecionado → liraa_item_not_found. Threads reais contra
# TEST_CITY_A, sem fixture transacional (o padrão do record_spec do 24b).
RSpec.describe VectorControl::RecordInspection, "× duas visitas ao mesmo item do LIRAa" do
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
      neighborhood = Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual")
      household = registry_household!(micro_area: area, neighborhood_id: neighborhood.id)
      block = city_block!(neighborhood: neighborhood, number: "7")
      survey = LiraaSurvey.create!(name: "LIRAa #{SecureRandom.hex(2)}", starts_on: Time.zone.today, ends_on: Time.zone.today + 6)
      stratum = LiraaStratum.create!(liraa_survey: survey, name: "Estrato 1", mode: "census")
      item = LiraaDrawItem.create!(liraa_stratum: stratum, city_block: block, household: household, position: 1)
      survey.update!(status: "drawn", drawn_at: Time.current, parameters_version: 1)
      { agent: agent.id, team: team.id, household: household.id, item: item.id }
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

  def visit_now(go)
    go.pop(timeout: 5) or raise "timeout esperando go"
    in_city do
      report = { "activity" => "liraa", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
                 "liraa_draw_item_id" => @ids[:item] }
      HomeVisits::Record.call(params: { "client_uuid" => SecureRandom.uuid, "team_id" => @ids[:team],
                                        "occurred_at" => Time.current.change(usec: 0).iso8601, "household_id" => @ids[:household],
                                        "subject" => "none", "outcome" => 1, "reasons" => [ 1 ], "vector_inspection" => report },
                              by: User.find(@ids[:agent]), vector_control: true)
    end
  rescue StandardError => e
    e
  end

  it "duas visitas ao mesmo item pending em threads → uma grava, a outra liraa_item_not_found" do
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
    threads << (holder = Thread.new { first_result << visit_now(go_first) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << visit_now(go_second) })
    go_second << true
    expect(wait_for_lock_wait).to be(true) # a segunda espera a trava (perfil → item)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    first, second = first_result.pop(timeout: 1), second_result.pop(timeout: 1)
    expect([ first, second ]).to all(be_a(Result)) # nenhuma exceção (deadlock, trigger)
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :liraa_item_not_found, { path: "vector_inspection.liraa_draw_item_id" } ])
    in_city do
      expect(LiraaDrawItem.find(@ids[:item])).to have_attributes(status: "inspected", version: 2)
      expect(VectorInspection.where(liraa_draw_item_id: @ids[:item]).count).to eq(1)
      expect(HomeVisit.where(household_id: @ids[:household]).count).to eq(1)
    end
  end
end
