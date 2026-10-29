require "rails_helper"

# Módulo 27a, Task 6 (ADR 0045; Pharmacy::SendTransfer e ReceiveTransfer): a
# transferência sob disputa. Threads reais contra TEST_CITY_A (sem fixture
# transacional), o padrão de record_entry_concurrency_spec.rb, e DETERMINÍSTICAS:
# uma transação segura a trava sem commitar, a outra chega e a prova de que
# esperou vem de pg_stat_activity (wait_for_lock_wait), nunca de sleep.
#
#   1. duas saídas do mesmo lote que não cabem juntas: uma envia, a outra espera
#      o lote, relê o saldo sob a trava e recusa; o saldo nunca fica negativo;
#   2. dois recebimentos da mesma transferência: um credita, o outro espera e
#      termina em already_received;
#   3. envio × desativação do destino, nas duas ordens: a trava FOR SHARE do
#      destino no envio e o `pending_work?` da desativação (Task 4) não se
#      perdem (nenhuma transferência fica órfã num local desativado).
# O catálogo da plataforma não é gravado: o comando recebe itens de mentira (o
# lote não tem FK para o catálogo, que mora em outro banco).
RSpec.describe "Transferência de estoque sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:item) { Struct.new(:id, :catmat_code, :status, :dosage_form).new(SecureRandom.uuid, 9_900_778, "active", "comprimido") }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  before do
    @rows = in_city do
      @empty = empty_tables
      admin = staff_with("admin-corrida-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      central = StockLocation.create!(kind: "central", name: "Central de Corrida", updated_by_user: admin)
      unit = HealthUnit.create!(name: "UBS Corrida", kind: "ubs", active: true, dispenses: true)
      farmacia = StockLocation.create!(kind: "unit", name: "Farmácia da UBS Corrida", health_unit: unit, updated_by_user: admin)
      entry = Pharmacy::RecordEntry.call(location: central, kind: "opening", document: nil, by: admin, catalog: { item.id => item },
                                         items: [ { "catalog_item_id" => item.id, "lot_number" => "CORRIDA-1", "expires_on" => (Time.zone.today + 90).iso8601,
                                                    "quantity" => "100" } ])
      raise entry.inspect if entry.failure?

      { admin: admin.id, central: central.id, farmacia: farmacia.id, lot: entry.payload.fetch(:movements).sole.stock_lot_id }
    end
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
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

  def central = StockLocation.find(@rows[:central])
  def farmacia = StockLocation.find(@rows[:farmacia])
  def admin = User.find(@rows[:admin])
  def balance(location_id) = Pharmacy::Ledger.balance(location_id: location_id, lot_id: @rows[:lot])

  # Sem in_city: a thread chama de dentro do seu próprio in_city.
  def send!(quantity)
    Pharmacy::SendTransfer.call(from: central, to: farmacia, items: [ { "lot_id" => @rows[:lot], "quantity" => quantity } ], by: admin)
  rescue StandardError => e
    e
  end

  def receive!(transfer_id, quantity = "60")
    Pharmacy::ReceiveTransfer.call(transfer: StockTransfer.find(transfer_id), items: [ { "lot_id" => @rows[:lot], "quantity_received" => quantity } ], by: admin)
  rescue StandardError => e
    e
  end

  # Segura o que `work` travou até `release`, sem commitar; devolve o resultado
  # pela fila `out`. `holding` avisa que a trava já está tomada.
  def hold(holding, out, &work)
    threads << Thread.new do
      Thread.current.report_on_exception = false
      out << in_city do
        ApplicationRecord.transaction do
          result = work.call
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
          result
        end
      end
    end
  end

  def wait_until_blocked(thread)
    expect(wait_for_lock_wait).to be(true)
    expect(thread.join(0.3)).to be_nil
  end

  it "duas saídas de 60 do mesmo lote de 100: uma envia, a outra espera o lote e recusa com insufficient_balance; nada negativo" do
    holding = Queue.new
    first = Queue.new
    hold(holding, first) { send!("60") }
    holding.pop(timeout: 5) or raise "a primeira não segurou o lote"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { send!("60") }
    end
    wait_until_blocked(other)

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(other.join(10)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a, b ]).to all(be_a(Result))
    expect(a).to be_ok
    expect([ b.reason, b.details[:path], b.details[:problems] ]).to eq([ :insufficient_balance, "items[0].quantity",
                                                                         [ { path: "items[0].quantity", error: "insufficient_balance" } ] ])
    in_city do
      expect(balance(@rows[:central])).to eq(40)
      expect(StockTransfer.count).to eq(1)
      expect(StockTransferItem.count).to eq(1)
      expect(StockMovement.where(kind: "transfer_out").count).to eq(1)
    end
  end

  it "duas saídas de 50 do mesmo lote de 100: as duas cabem, as duas gravam, e o saldo fecha em zero" do
    holding = Queue.new
    first = Queue.new
    hold(holding, first) { send!("50") }
    holding.pop(timeout: 5) or raise "a primeira não segurou o lote"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { send!("50") }
    end
    wait_until_blocked(other)
    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(other.join(10)).to be(other)
    expect([ first.pop(timeout: 1), second.pop(timeout: 1) ].map { |r| r.respond_to?(:ok?) && r.ok? }).to eq([ true, true ])
    in_city do
      expect(balance(@rows[:central])).to eq(0)
      expect(StockTransfer.count).to eq(2)
    end
  end

  it "dois recebimentos da mesma transferência: um credita o destino, o outro espera o lote e termina em already_received" do
    transfer_id = in_city { send!("60").payload.fetch(:transfer).id }
    holding = Queue.new
    first = Queue.new
    hold(holding, first) { receive!(transfer_id) }
    holding.pop(timeout: 5) or raise "o primeiro recebimento não segurou o lote"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { receive!(transfer_id) }
    end
    wait_until_blocked(other)

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(other.join(10)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a, b ]).to all(be_a(Result))
    expect(a).to be_ok
    expect([ b.reason, b.details ]).to eq([ :already_received, {} ])
    in_city do
      expect(balance(@rows[:farmacia])).to eq(60)
      expect(StockMovement.where(kind: "transfer_in").count).to eq(1)
      expect(StockTransfer.sole.status).to eq("received")
    end
  end

  it "envio em curso × desativação do destino: a desativação espera a trava do destino e, relendo, recusa por transferência enviada" do
    holding = Queue.new
    first = Queue.new
    hold(holding, first) { send!("10") }
    holding.pop(timeout: 5) or raise "o envio não segurou o destino"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { Pharmacy::SaveLocation.call(attrs: { "active" => false }, by: admin, location: farmacia) }
    end
    wait_until_blocked(other)

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(other.join(10)).to be(other)
    expect(first.pop(timeout: 1)).to be_ok
    expect(second.pop(timeout: 1).reason).to eq(:location_has_stock)
    in_city do
      expect(StockLocation.find(@rows[:farmacia]).active).to be(true)
      expect(StockTransfer.where(status: "sent", to_location_id: @rows[:farmacia]).count).to eq(1)
    end
  end

  it "desativação do destino em curso × envio: o envio espera a trava do destino e, relendo, recusa com location_inactive, sem nada gravado" do
    holding = Queue.new
    first = Queue.new
    hold(holding, first) { Pharmacy::SaveLocation.call(attrs: { "active" => false }, by: admin, location: farmacia) }
    holding.pop(timeout: 5) or raise "a desativação não segurou o destino"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { send!("10") }
    end
    wait_until_blocked(other)

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(other.join(10)).to be(other)
    expect(first.pop(timeout: 1)).to be_ok
    result = second.pop(timeout: 1)
    expect([ result.reason, result.details ]).to eq([ :location_inactive, { path: "to_location_id" } ])
    in_city do
      expect(StockTransfer.count).to eq(0)
      expect(balance(@rows[:central])).to eq(100)
    end
  end
end
