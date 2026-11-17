require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054; contrato §4, §17; plano, A-1, A-2, W-5, W-6,
# W-7, Review Focus 2 e 4): a baixa das medidas químicas do boletim pelo razão
# do 27a, gravada pela visita (HomeVisits::Record → RecordInspection →
# ApplyStock). Um lote só, o primeiro do FEFO com saldo bastante, sem dividir;
# sem local, sem saldo ou sem lote, a visita é gravada e a medida ganha a
# falta (nunca a recusa); a retirada estorna uma vez e concilia a falta pelo
# sistema.
RSpec.describe VectorControl::ApplyStock, type: :model do
  let!(:city) { vector_city! }
  let(:team) { registry_team! }
  let(:agent) { endemic_agent!(team: team) }
  let(:area) { MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area }
  let(:household) { registry_household!(micro_area: area) }
  let(:product) { vector_product!(charge_size: "2.00") }
  let(:location) { vector_location! }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def ago(minutes) = [ minutes.minutes.ago, Time.current.beginning_of_day ].max.change(usec: 0)

  def report(charges: 1, measured: product)
    { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
      "measures" => [ { "method" => "focal", "vector_product_id" => measured.id, "charges" => charges } ] }
  end

  def record!(inspection_report = report, at: ago(5), home: household)
    params = { "client_uuid" => SecureRandom.uuid, "team_id" => team.id, "occurred_at" => at.iso8601, "household_id" => home.id,
               "subject" => "none", "outcome" => 1, "reasons" => [], "shared" => false, "vector_inspection" => inspection_report }
    result = HomeVisits::Record.call(params: params, by: agent, vector_control: true)
    raise "visita recusada: #{result.reason} #{result.details}" if result.failure?

    result.payload[:visit]
  end

  def measure_of(visit) = VectorInspection.find_by!(home_visit_id: visit.id).measures.where.not(vector_product_id: nil).sole
  def balance(lot) = Pharmacy::Ledger.balance(location_id: location.id, lot_id: lot.id)
  def withdraw(visit) = HomeVisits::Withdraw.call(visit, by: agent, expected_state: "recorded", reason: "registrada no imóvel errado")

  it "baixa do lote que vence primeiro, um lote só, sem dividir" do
    vector_stock_location!(location)
    first = vector_lot!(location, product: product, quantity: "3", expires_on: today + 30, lot_number: "A")
    second = vector_lot!(location, product: product, quantity: "5", expires_on: today + 60, lot_number: "B")

    visit = record!
    movement = StockMovement.where(kind: "vector_application").sole
    expect(movement).to have_attributes(stock_location_id: location.id, stock_lot_id: first.id, quantity: BigDecimal("-2"),
                                        vector_product_id: product.id, vector_inspection_measure_id: measure_of(visit).id,
                                        recorded_by_user_id: agent.id)
    expect(measure_of(visit).quantity).to eq(BigDecimal("2"))

    # Saldo 1 no primeiro: a próxima baixa de 2 vai inteira para o segundo.
    record!(at: ago(3), home: registry_household!(micro_area: area))
    expect([ balance(first), balance(second) ]).to eq([ BigDecimal("1"), BigDecimal("3") ])
    expect(StockMovement.where(kind: "vector_application").pluck(:stock_lot_id)).to contain_exactly(first.id, second.id)
    expect(VectorStockShortfall.count).to eq(0)
  end

  it "quantidade = (cargas × carga).ceil(2), nunca menos que o aplicado (A-2)" do
    vector_stock_location!(location)
    small = vector_product!(charge_size: "0.15")
    vector_lot!(location, product: small, quantity: "5")
    visit = record!(report(charges: 1.25, measured: small))
    expect(measure_of(visit).quantity).to eq(BigDecimal("0.19"))
    expect(StockMovement.where(kind: "vector_application").sole.quantity).to eq(BigDecimal("-0.19"))
  end

  it "sem local → no_location sem local; sem lote do produto no local → no_lot; saldo 1 para 2, lote zerado, vencido ou bloqueado → insufficient_balance (Q21)" do
    no_location = record!(at: ago(30))
    expect(measure_of(no_location).shortfall).to have_attributes(cause: "no_location", stock_location_id: nil, quantity: BigDecimal("2"),
                                                                 vector_product_id: product.id, reconciled_at: nil)

    vector_stock_location!(location)
    no_lot = record!(at: ago(25), home: registry_household!(micro_area: area))
    expect(measure_of(no_lot).shortfall).to have_attributes(cause: "no_lot", stock_location_id: location.id)

    lot = vector_lot!(location, product: product, quantity: "1")
    short = record!(at: ago(20), home: registry_household!(micro_area: area))
    expect(measure_of(short).shortfall).to have_attributes(cause: "insufficient_balance", stock_location_id: location.id)
    expect(balance(lot)).to eq(BigDecimal("1"))

    other = vector_product!
    vector_lot!(location, product: other, quantity: "9", expires_on: today - 1)
    expired = record!(report(measured: other), at: ago(15), home: registry_household!(micro_area: area))
    expect(measure_of(expired).shortfall.cause).to eq("insufficient_balance")

    blocked_product = vector_product!
    lot_block!(location, vector_lot!(location, product: blocked_product, quantity: "9"))
    blocked = record!(report(measured: blocked_product), at: ago(10), home: registry_household!(micro_area: area))
    expect(measure_of(blocked).shortfall.cause).to eq("insufficient_balance")

    # Lote zerado: há lote do produto no local, sem saldo → insufficient_balance.
    drained_product = vector_product!
    drained = vector_lot!(location, product: drained_product, quantity: "2")
    record!(report(measured: drained_product), at: ago(9), home: registry_household!(micro_area: area))
    expect(balance(drained)).to eq(0)
    zero = record!(report(measured: drained_product), at: ago(8), home: registry_household!(micro_area: area))
    expect(measure_of(zero).shortfall.cause).to eq("insufficient_balance")

    # Local desativado depois de escolhido: no_location.
    location.update!(active: false)
    inactive = record!(at: ago(5), home: registry_household!(micro_area: area))
    expect(measure_of(inactive).shortfall).to have_attributes(cause: "no_location", stock_location_id: nil)

    expect(HomeVisit.count).to eq(8)
    expect(StockMovement.where(kind: "vector_application").count).to eq(1) # só a do lote que zerou
  end

  it "evento shortfall_recorded só com o id" do
    visit = record!
    shortfall = measure_of(visit).shortfall
    event = DomainEvent.where(name: "vector_stock.shortfall_recorded").sole
    expect(event.payload).to eq("vector_stock_shortfall_id" => shortfall.id)
  end

  it "a recusa do Ledger (Insufficient) só volta o savepoint: a visita fica, com a falta insufficient_balance" do
    vector_stock_location!(location)
    vector_lot!(location, product: product, quantity: "5")
    allow(Pharmacy::Ledger).to receive(:record!).and_wrap_original do |original, **kwargs|
      raise Pharmacy::Ledger::Insufficient, kwargs[:lot].id if kwargs[:kind] == "vector_application"

      original.call(**kwargs)
    end
    visit = record!
    expect(HomeVisit.where(id: visit.id)).to exist
    expect(measure_of(visit).shortfall).to have_attributes(cause: "insufficient_balance", stock_location_id: location.id)
    expect(StockMovement.where(kind: "vector_application")).to be_empty
  end

  it "Review Focus 4: retirada estorna exatamente uma vez (reversal positivo), concilia a falta pelo sistema; a segunda retirada → visit_changed sem novo movimento" do
    vector_stock_location!(location)
    lot = vector_lot!(location, product: product, quantity: "3")
    other = vector_product!(uses: %w[perifocal])
    inspection_report = report.merge("measures" => [ { "method" => "focal", "vector_product_id" => product.id, "charges" => 1 },
                                                     { "method" => "perifocal", "vector_product_id" => other.id, "charges" => 1 } ])
    visit = record!(inspection_report)
    expect(balance(lot)).to eq(BigDecimal("1"))
    shortfall = VectorStockShortfall.sole
    expect(shortfall).to have_attributes(cause: "no_lot", vector_product_id: other.id)

    expect(withdraw(visit)).to be_ok
    reversal = StockMovement.where(kind: "vector_application_reversal").sole
    applied = StockMovement.where(kind: "vector_application").sole
    expect(reversal).to have_attributes(stock_lot_id: lot.id, stock_location_id: location.id, quantity: BigDecimal("2"),
                                        vector_inspection_measure_id: applied.vector_inspection_measure_id)
    expect(balance(lot)).to eq(BigDecimal("3"))
    expect(shortfall.reload).to have_attributes(reconciled_by_user_id: nil, reconciliation_note: nil)
    expect(shortfall.reconciled_at).to be_present

    movements = StockMovement.count
    again = withdraw(visit.reload)
    expect(again.reason).to eq(:visit_changed)
    expect(StockMovement.count).to eq(movements)
    expect(balance(lot)).to eq(BigDecimal("3"))
  end
end

# Rodada de correção 1: a baixa escolhe SÓ entre os lotes que o ApplyStock
# travou antes do local; nunca trava lote depois do local (a ordem do Ledger).
RSpec.describe VectorControl::DeductStock, type: :model do
  let!(:city) { vector_city! }
  let(:product) { vector_product!(charge_size: "2.00") }
  let(:location) { vector_location! }
  let(:today) { Time.zone.today }

  before { allow(Ledi::DeliverJob).to receive(:perform_later) }

  def measure = Struct.new(:quantity, :vector_product_id).new(BigDecimal("2"), product.id)

  it "lote com saldo fora do conjunto travado não é candidato (insufficient_balance, há lote no local), e nenhum lote é travado aqui" do
    fresh_lot = vector_lot!(location, product: product, quantity: "5", expires_on: today + 30)
    later_lot = vector_lot!(location, product: product, quantity: "5", expires_on: today + 60)
    expect(Pharmacy::Ledger).not_to receive(:lock_lots!)

    none = described_class.call(measure: measure, location_id: location.id, today: today, locked: {})
    expect(none.payload).to include(shortfall_cause: "insufficient_balance", location: location)

    only_later = described_class.call(measure: measure, location_id: location.id, today: today, locked: { later_lot.id => later_lot })
    expect(only_later.payload).to include(lot: later_lot, quantity: BigDecimal("2"))
    expect(only_later.payload[:lot]).not_to eq(fresh_lot)
  end

  it "o ApplyStock trava os lotes de todas as medidas numa chamada só, antes do local" do
    other = vector_product!(uses: %w[perifocal])
    vector_stock_location!(location)
    vector_lot!(location, product: product, quantity: "5")
    vector_lot!(location, product: other, quantity: "5")
    calls = []
    allow(Pharmacy::Ledger).to receive(:lock_lots!).and_wrap_original { |original, ids| calls << [ :lots, ids.size ] && original.call(ids) }
    allow(Pharmacy::Ledger).to receive(:lock_location!).and_wrap_original { |original, id| calls << [ :location ] && original.call(id) }

    agent = endemic_agent!
    member = HealthTeamMember.active.find_by!(professional: agent.professional)
    household = registry_household!(micro_area: MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area)
    report = { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
               "measures" => [ { "method" => "focal", "vector_product_id" => product.id, "charges" => 1 },
                               { "method" => "perifocal", "vector_product_id" => other.id, "charges" => 1 } ] }
    result = HomeVisits::Record.call(params: { "client_uuid" => SecureRandom.uuid, "team_id" => member.health_team_id,
                                               "occurred_at" => Time.current.change(usec: 0).iso8601, "household_id" => household.id,
                                               "subject" => "none", "outcome" => 1, "reasons" => [], "vector_inspection" => report },
                                     by: agent, vector_control: true)
    expect(result).to be_ok
    expect(calls.first).to eq([ :lots, 2 ])
    expect(calls.count { |call| call.first == :lots }).to eq(1)
    expect(StockMovement.where(kind: "vector_application").count).to eq(2)
  end
end

# Review Focus 2 (plano; contrato §4): duas visitas (dois agentes, dois
# domicílios) baixam o mesmo produto com saldo para uma só. A primeira grava a
# baixa e fica parada antes do commit; a segunda leu o mesmo saldo no FEFO e
# espera na trava do lote; solta a primeira, a segunda relê o saldo sob a trava
# e grava a visita com a falta insufficient_balance. As duas gravadas, saldo
# nunca negativo. Threads reais contra TEST_CITY_A, sem fixture transacional
# (o padrão do record_inspection_spec).
RSpec.describe VectorControl::ApplyStock, "× duas visitas e a última carga" do
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
      first_agent = endemic_agent!(team: team)
      second_agent = endemic_agent!(team: team)
      areas = [ first_agent, second_agent ].map { |agent| MicroAreaFieldAssignment.find_by!(professional: agent.professional).micro_area }
      product = vector_product!(charge_size: "2.00")
      location = vector_location!
      vector_stock_location!(location)
      lot = vector_lot!(location, product: product, quantity: "2")
      { team: team.id, agents: [ first_agent.id, second_agent.id ], households: areas.map { |area| registry_household!(micro_area: area).id },
        product: product.id, location: location.id, lot: lot.id }
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

  def visit_now(go, index)
    go.pop(timeout: 5) or raise "timeout esperando go"
    in_city do
      report = { "activity" => "li", "work_type" => "routine", "situation" => "worked", "educational_action" => false,
                 "measures" => [ { "method" => "focal", "vector_product_id" => @ids[:product], "charges" => 1 } ] }
      HomeVisits::Record.call(params: { "client_uuid" => SecureRandom.uuid, "team_id" => @ids[:team],
                                        "occurred_at" => Time.current.change(usec: 0).iso8601, "household_id" => @ids[:households][index],
                                        "subject" => "none", "outcome" => 1, "reasons" => [], "vector_inspection" => report },
                              by: User.find(@ids[:agents][index]), vector_control: true)
    end
  rescue StandardError => e
    e
  end

  it "saldo 2 e duas visitas de 2 em threads → uma vector_application, a segunda falta insufficient_balance (Q21), as duas gravadas, saldo 0" do
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
    threads << (holder = Thread.new { first_result << visit_now(go_first, 0) })
    go_first << true
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    go_second = Queue.new
    second_result = Queue.new
    threads << (other = Thread.new { second_result << visit_now(go_second, 1) })
    go_second << true
    expect(wait_for_lock_wait).to be(true) # a segunda espera a trava do lote

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    first, second = first_result.pop(timeout: 1), second_result.pop(timeout: 1)
    expect([ first, second ]).to all(be_a(Result)) # nenhuma exceção (deadlock, trigger)
    expect([ first, second ]).to all(be_ok)
    in_city do
      expect(HomeVisit.where(household_id: @ids[:households]).count).to eq(2)
      expect(StockMovement.where(kind: "vector_application").count).to eq(1)
      shortfall = VectorStockShortfall.sole
      expect(shortfall).to have_attributes(cause: "insufficient_balance", stock_location_id: @ids[:location])
      expect(VectorInspection.find_by!(home_visit_id: second.payload[:visit].id).measures.sole.id).to eq(shortfall.vector_inspection_measure_id)
      expect(Pharmacy::Ledger.balance(location_id: @ids[:location], lot_id: @ids[:lot])).to eq(BigDecimal("0"))
    end
  end
end
