require "rails_helper"

# Módulo 27a, Task 7 (ADR 0045; Pharmacy::RequestAdjustment e DecideAdjustment):
# o ajuste sob disputa. Threads reais contra TEST_CITY_A (sem fixture
# transacional), o padrão de transfer_concurrency_spec.rb, e DETERMINÍSTICAS: uma
# transação segura a trava sem commitar, a outra chega e a prova de que esperou
# vem de pg_stat_activity (wait_for_lock_wait), nunca de sleep.
#
#   1. duas aprovações do mesmo ajuste: uma aplica, a outra espera e termina em
#      not_pending; o saldo muda uma vez só;
#   2. aprovação × saída concorrente do mesmo lote: a aprovação espera o lote,
#      relê o saldo sob a trava e recusa com insufficient_balance; o ajuste
#      continua pending e o saldo nunca fica negativo;
#   3. pedido `pending` × desativação do local, nas duas ordens: a trava FOR SHARE
#      do local (e da unidade) no pedido e o `pending_work?` da desativação
#      (Task 4/6b) não se perdem;
#   4. duas contagens do mesmo lote ao mesmo tempo: só uma vira `pending`; a outra
#      espera o lote e termina em adjustment_pending (nada de delta aplicado duas vezes);
#   5. pedido `pending` × desativação da UNIDADE de saúde (HealthUnitsController#
#      deactivate trava a unidade FOR UPDATE e lê PendingWork.any?, H14): a
#      desativação espera o pedido e enxerga o ajuste.
# O catálogo da plataforma não é gravado: o comando recebe itens de mentira.
RSpec.describe "Ajuste de estoque sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:item) { Struct.new(:id, :catmat_code, :status, :dosage_form).new(SecureRandom.uuid, 9_900_779, "active", "comprimido") }

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
      lots = [ central, farmacia ].map do |location|
        entry = Pharmacy::RecordEntry.call(location: location, kind: "opening", document: nil, by: admin, catalog: { item.id => item },
                                           items: [ { "catalog_item_id" => item.id, "lot_number" => "CORRIDA-A", "expires_on" => (Time.zone.today + 90).iso8601,
                                                      "quantity" => "100" } ])
        raise entry.inspect if entry.failure?

        entry.payload.fetch(:movements).sole.stock_lot_id
      end
      raise "lote divergente" unless lots.uniq.one?

      users = Array.new(3) { pharmacy_staff!(central, "stock_keeper").id }
      { admin: admin.id, central: central.id, farmacia: farmacia.id, unit: unit.id, lot: lots.first, users: users,
        farmacia_keeper: pharmacy_staff!(farmacia, "stock_keeper").id }
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
  def lot = StockLot.find(@rows[:lot])
  def author = User.find(@rows[:users][0])
  def decider(index = 1) = User.find(@rows[:users][index])
  def balance(location_id = @rows[:central]) = Pharmacy::Ledger.balance(location_id: location_id, lot_id: @rows[:lot])

  # Sem in_city: a thread chama de dentro do seu próprio in_city.
  def request!(kind: "adjustment", counted: "85", quantity: nil, location: central, by: author)
    Pharmacy::RequestAdjustment.call(location: location, lot: lot, kind: kind, counted_quantity: counted, quantity: quantity,
                                     reason: "Contagem do inventário de outubro", by: by, settings: Pharmacy::Settings.current)
  rescue StandardError => e
    e
  end

  def decide!(adjustment_id, decision = "approve", by: decider)
    Pharmacy::DecideAdjustment.call(adjustment: StockAdjustment.find(adjustment_id), decision: decision, reason: nil, by: by)
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

  # Segura `first` e dispara `second` numa thread; prova que esperou, solta e devolve os dois resultados.
  def race(first, second)
    holding = Queue.new
    out_first = Queue.new
    hold(holding, out_first, &first)
    holding.pop(timeout: 5) or raise "o primeiro não segurou a trava"

    out_second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      out_second << in_city { second.call }
    end
    wait_until_blocked(other)

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(other.join(10)).to be(other)
    [ out_first.pop(timeout: 1), out_second.pop(timeout: 1) ]
  end

  it "duas aprovações do mesmo ajuste: uma aplica, a outra espera o lote e termina em not_pending; o saldo muda uma vez" do
    adjustment_id = in_city { request!.payload.fetch(:adjustment).id }
    first, second = race(-> { decide!(adjustment_id, by: decider(1)) }, -> { decide!(adjustment_id, by: decider(2)) })
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :not_pending, {} ])
    in_city do
      expect(balance).to eq(85)
      expect(StockMovement.where(kind: "adjustment").count).to eq(1)
      expect(StockAdjustment.find(adjustment_id)).to have_attributes(status: "approved", decided_by_user_id: decider(1).id)
    end
  end

  it "aprovação × saída concorrente do mesmo lote (90): a aprovação espera, relê o saldo sob a trava e recusa; continua pending" do
    adjustment_id = in_city { request!.payload.fetch(:adjustment).id } # delta -15
    first, second = race(-> { request!(kind: "loss", quantity: "90", by: decider(2)) }, -> { decide!(adjustment_id) })
    expect(first).to be_ok
    expect([ second.reason, second.details[:path], second.details[:problems] ]).to eq([ :insufficient_balance, "id",
                                                                                      [ { path: "id", error: "insufficient_balance" } ] ])
    in_city do
      expect(balance).to eq(10)
      expect(StockAdjustment.find(adjustment_id)).to have_attributes(status: "pending", decided_by_user_id: nil)
      expect(StockMovement.where(kind: "adjustment").count).to eq(0)
    end
  end

  it "pedido pending em curso × desativação do local: a desativação espera o local e, relendo, recusa por ajuste pendente" do
    # O saldo do central é zerado para a desativação só poder recusar pelo ajuste (e não pelo saldo).
    in_city { expect(request!(kind: "loss", quantity: "100", by: decider(2))).to be_ok }
    first, second = race(-> { request!(counted: "3") }, -> { Pharmacy::SaveLocation.call(attrs: { "active" => false }, by: User.find(@rows[:admin]), location: central) })
    expect(first.payload.fetch(:adjustment).status).to eq("pending")
    expect(second.reason).to eq(:location_has_stock)
    in_city do
      expect(StockLocation.find(@rows[:central]).active).to be(true)
      expect(StockAdjustment.where(status: "pending", stock_location_id: @rows[:central]).count).to eq(1)
    end
  end

  it "desativação do local em curso × pedido pending: o pedido espera o local e, relendo, recusa com location_inactive, sem nada gravado" do
    in_city { expect(request!(kind: "loss", quantity: "100", by: decider(2))).to be_ok }
    first, second = race(-> { Pharmacy::SaveLocation.call(attrs: { "active" => false }, by: User.find(@rows[:admin]), location: central) },
                         -> { request!(counted: "3") })
    expect(first).to be_ok
    expect([ second.reason, second.details ]).to eq([ :location_inactive, { path: "location_id" } ])
    in_city do
      expect(StockAdjustment.where(status: "pending").count).to eq(0)
      expect(StockLocation.find(@rows[:central]).active).to be(false)
    end
  end

  it "pedido pending na farmácia da UBS × desativação da unidade (H14): a desativação espera a trava da unidade e enxerga o ajuste" do
    first, second = race(-> { request!(location: farmacia, by: User.find(@rows[:farmacia_keeper])) },
                         lambda {
                           HealthUnit.find(@rows[:unit]).with_lock { Pharmacy::PendingWork.any?(StockLocation.find(@rows[:farmacia])) }
                         })
    expect(first.payload.fetch(:adjustment).status).to eq("pending")
    expect(second).to be(true)
  end

  it "duas contagens do mesmo lote (85): uma vira pending, a outra espera o lote e termina em adjustment_pending; um ajuste só" do
    first, second = race(-> { request!(by: decider(1)) }, -> { request!(by: decider(2)) })
    expect(first.payload.fetch(:adjustment).status).to eq("pending")
    expect([ second.reason, second.details ]).to eq([ :adjustment_pending, { path: "lot_id" } ])
    in_city do
      expect(StockAdjustment.where(status: "pending", stock_lot_id: @rows[:lot]).count).to eq(1)
      expect(StockAdjustment.count).to eq(1)
      expect(balance).to eq(100)
    end
  end
end
