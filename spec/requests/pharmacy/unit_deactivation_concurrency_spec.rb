require "rails_helper"

# Módulo 27a, Task 12 (contrato H14; ADR 0045): a desativação da unidade de
# saúde (POST /attendance/units/:id/deactivate, HealthUnitsController#deactivate)
# concorrendo com Pharmacy::SendTransfer para a farmácia dela, nas duas ordens.
# Ou a transferência entra e a desativação recebe 409 pharmacy_pending, ou a
# desativação entra e a transferência recebe location_inactive: nunca uma
# transferência `sent` para uma unidade inativa.
#
# Threads reais contra TEST_CITY_A (sem fixture transacional) e a requisição de
# verdade, pela pilha inteira do Rails, numa ActionDispatch::Integration::Session
# por thread. Por isso NÃO é `type: :request`: o hook desse tipo grava a City no
# banco da plataforma e, sem fixture transacional, ela ficaria lá; aqui o
# catálogo de cidades é um stub que devolve TEST_CITY_A, e a sessão do admin
# vive no banco da cidade (apagada no `after`, como nos outros specs de threads).
# A prova de que uma transação esperou vem de pg_stat_activity, nunca de sleep.
RSpec.describe "Desativação da unidade × envio de transferência para a farmácia" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:item) { Struct.new(:id, :catmat_code, :status, :dosage_form).new(SecureRandom.uuid, 9_900_781, "active", "comprimido") }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  before do
    # A mesma cidade de teste (mesmo slug, mesmo banco), com a versão do esquema
    # que o CitySchema.behind? confere (a constante não a carrega).
    served = TEST_CITY_A.dup.tap { |city| city.schema_version = CitySchema.expected_version.to_s }
    allow(CityCatalog).to receive(:find_by_host).and_return(served)
    allow(Pharmacy::Gate).to receive(:usable?).and_return(true)
    @rows = in_city do
      @empty = empty_tables
      admin = staff_with("admin-corrida-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      central = StockLocation.create!(kind: "central", name: "Central de Corrida", updated_by_user: admin)
      unit = HealthUnit.create!(name: "UBS Corrida", kind: "ubs", active: true, dispenses: true)
      farmacia = StockLocation.create!(kind: "unit", name: "Farmácia da UBS Corrida", health_unit: unit, updated_by_user: admin)
      opened = Pharmacy::RecordEntry.call(location: central, kind: "opening", document: nil, by: admin, catalog: { item.id => item },
                                          items: [ { "catalog_item_id" => item.id, "lot_number" => "DESATIVA-1", "expires_on" => (Time.zone.today + 90).iso8601,
                                                     "quantity" => "100" } ])
      raise opened.inspect if opened.failure?

      session = admin.sessions.create!(user_agent: "rspec", ip_address: "127.0.0.1")
      cookie = ActionDispatch::TestRequest.create.cookie_jar.tap { |jar| jar.signed[:session_id] = session.id }[:session_id]
      { admin: admin.id, central: central.id, farmacia: farmacia.id, unit: unit.id, cookie: cookie, lot: opened.payload.fetch(:movements).sole.stock_lot_id }
    end
  end

  after do
    3.times { release << true }
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

  def balance(location_id) = in_city { Pharmacy::Ledger.balance(location_id: location_id, lot_id: @rows[:lot]) }

  # Sem in_city: quem chama já está no seu.
  def send!
    Pharmacy::SendTransfer.call(from: StockLocation.find(@rows[:central]), to: StockLocation.find(@rows[:farmacia]), by: User.find(@rows[:admin]),
                                items: [ { "lot_id" => @rows[:lot], "quantity" => "10" } ])
  rescue StandardError => e
    e
  end

  # A requisição inteira, na thread de quem chama: [ status, corpo ].
  def deactivate!
    http = ActionDispatch::Integration::Session.new(Rails.application)
    http.host! "#{TEST_CITY_A.slug}.rotasaude.app"
    http.cookies[:session_id] = @rows[:cookie]
    http.post "/attendance/units/#{@rows[:unit]}/deactivate", params: "{}", headers: { "CONTENT_TYPE" => "application/json" }
    [ http.response.status, JSON.parse(http.response.body) ]
  rescue StandardError => e
    e
  end

  # Segura o que `work` travou até `release`, sem commitar.
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
    holding.pop(timeout: 5) or raise "a primeira transação não segurou as travas"
  end

  def run_in_thread(out, &work)
    threads << thread = Thread.new do
      Thread.current.report_on_exception = false
      out << work.call
    end
    thread
  end

  def wait_until_blocked(thread)
    expect(wait_for_lock_wait).to be(true)
    expect(thread.join(0.3)).to be_nil
  end

  def finish(second)
    release << true
    [ threads.first, second ].each { |thread| expect(thread.join(10)).to be(thread) }
  end

  it "o envio entra primeiro: a desativação espera a trava da unidade e, relendo, recebe 409 pharmacy_pending; a unidade segue ativa" do
    sent = Queue.new
    hold(Queue.new, sent) { send! }

    deactivated = Queue.new
    other = run_in_thread(deactivated) { deactivate! }
    wait_until_blocked(other)

    finish(other)
    expect(sent.pop(timeout: 1)).to be_ok
    expect(deactivated.pop(timeout: 1)).to eq([ 409, { "error" => "pharmacy_pending" } ])
    in_city do
      expect(HealthUnit.find(@rows[:unit]).active).to be(true)
      expect(StockLocation.find(@rows[:farmacia]).active).to be(true)
      expect(StockTransfer.where(status: "sent", to_location_id: @rows[:farmacia]).count).to eq(1)
      expect(StockMovement.where(kind: "transfer_out").count).to eq(1)
    end
    expect(balance(@rows[:central])).to eq(90)
  end

  it "a desativação entra primeiro: o envio espera a trava da unidade e, relendo a unidade inativa, recebe location_inactive; nada gravado" do
    # A conferência da pendência já olhou (e não achou nada) quando a desativação
    # para, ainda com a unidade travada FOR UPDATE.
    holding = Queue.new
    allow(Pharmacy::PendingWork).to receive(:any?).and_wrap_original do |original, *args|
      found = original.call(*args)
      holding << true
      release.pop(timeout: 10) or raise "timeout esperando release"
      found
    end
    deactivated = Queue.new
    threads << Thread.new do
      Thread.current.report_on_exception = false
      deactivated << deactivate!
    end
    holding.pop(timeout: 5) or raise "a desativação não segurou a unidade"

    sent = Queue.new
    other = run_in_thread(sent) { in_city { send! } }
    wait_until_blocked(other)

    finish(other)
    status, body = deactivated.pop(timeout: 1)
    expect([ status, body.dig("unit", "active") ]).to eq([ 200, false ])
    result = sent.pop(timeout: 1)
    expect(result).to be_a(Result)
    expect([ result.reason, result.details ]).to eq([ :location_inactive, { path: "to_location_id" } ])
    in_city do
      expect(HealthUnit.find(@rows[:unit]).active).to be(false)
      expect(StockTransfer.count).to eq(0)
      expect(StockMovement.where(kind: "transfer_out").count).to eq(0)
    end
    expect(balance(@rows[:central])).to eq(100)
  end
end
