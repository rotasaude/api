require "rails_helper"

# Review Focus 4: duas aberturas ao mesmo tempo do último kit — a trava do
# lote (FOR UPDATE antes de somar os movimentos) serializa; uma passa, a
# outra leva insufficient_balance; o saldo fica 0 e nunca negativo. Se a
# conta da aplicação falhar, o trigger do saldo recusa (cinto de segurança).
RSpec.describe "Saídas concorrentes do estoque" do
  self.use_transactional_tests = false

  let(:release_gate) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |t| %w[schema_migrations ar_internal_metadata].include?(t) }
              .select { |t| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)})") }
  end

  before do
    @rows = in_city do
      @empty = empty_tables
      provider = lab_provider!
      staff = lab_staff!
      supply = LabSupply.create!(exam_provider: provider, name: "Creatinina Jaffé", kind: "reagent", unit: "kit", tests_per_package: 300,
                                 minimum_stock: 1, expiry_alert_days: 30, lab_exam_ids: [])
      lot = Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => "CR1", "expires_on" => (Time.zone.today + 90).iso8601,
                                              "supplier" => "Distribuidora", "origin" => "purchase", "quantity" => 1 }, by: staff).payload[:lot]
      { lot_id: lot.id, staff: [ staff.id, lab_staff!.id ] }
    end
  end

  after do
    3.times { release_gate << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError, ScriptError # join relança o erro da thread; a limpeza abaixo tem de rodar sempre
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        @empty.to_a.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
  end

  def open_last_kit(user_id)
    Lab::Inventory::RecordMovement.call(lot: LabSupplyLot.find(@rows[:lot_id]), kind: "opening", quantity: 1, reason: nil,
                                        by: User.find(user_id), admin: false)
  end

  def movements = in_city { LabSupplyMovement.where(lab_supply_lot_id: @rows[:lot_id]).order(:created_at).pluck(:kind, :quantity) }

  it "ao mesmo tempo: uma abertura passa, a outra é recusada; o saldo fica 0" do
    start = Queue.new
    out = Queue.new
    @rows[:staff].each do |user_id|
      threads << Thread.new do
        in_city do
          start.pop(timeout: 10) or raise "timeout"
          out << open_last_kit(user_id)
        end
      end
    end
    2.times { start << true }
    results = [ out.pop(timeout: 10), out.pop(timeout: 10) ]
    expect(results.map { |r| r.ok? ? :ok : r.reason }).to contain_exactly(:ok, :insufficient_balance)
    in_city { expect(LabSupplyLot.find(@rows[:lot_id]).balance).to eq(0) }
    expect(movements).to eq([ [ "receipt", 1 ], [ "opening", -1 ] ])
  end

  it "a segunda espera a trava do lote enquanto a primeira não confirma, e então leva insufficient_balance" do
    holding = Queue.new
    first_out = Queue.new
    second_out = Queue.new
    threads << Thread.new do
      in_city do
        ApplicationRecord.transaction do
          first_out << open_last_kit(@rows[:staff].first)
          holding << true
          release_gate.pop(timeout: 10) or raise "timeout"
        end
      end
    end
    holding.pop(timeout: 10) or raise "timeout"
    threads << Thread.new { in_city { second_out << open_last_kit(@rows[:staff].last) } }
    sleep 0.3
    expect(second_out).to be_empty # parada na trava do lote
    release_gate << true
    first = first_out.pop(timeout: 10)
    second = second_out.pop(timeout: 10)
    expect(first).to be_ok
    expect(first.payload[:balance]).to eq(0)
    expect([ second.failure?, second.reason ]).to eq([ true, :insufficient_balance ])
    in_city { expect(LabSupplyLot.find(@rows[:lot_id]).balance).to eq(0) }
    expect(movements).to eq([ [ "receipt", 1 ], [ "opening", -1 ] ])
  end

  it "se a conta da aplicação errar, o trigger recusa o saldo negativo e nada é gravado" do
    expect(in_city { open_last_kit(@rows[:staff].first) }).to be_ok # saldo real 0
    allow_any_instance_of(LabSupplyLot).to receive(:balance).and_return(100)
    result = in_city { open_last_kit(@rows[:staff].last) }
    expect([ result.failure?, result.reason ]).to eq([ true, :insufficient_balance ])
    expect(movements).to eq([ [ "receipt", 1 ], [ "opening", -1 ] ])
    in_city { expect(LabSupplyMovement.where(lab_supply_lot_id: @rows[:lot_id]).sum(:quantity)).to eq(0) }
    expect(in_city { DomainEvent.where(name: "lab_supply_movement.recorded").count }).to eq(1)
  end
end
