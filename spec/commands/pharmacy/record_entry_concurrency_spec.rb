require "rails_helper"

# Módulo 27a, Task 5 (ADR 0045; Pharmacy::RecordEntry): duas notas disputando
# os mesmos lotes NOVOS em ordem inversa não se travam (os lotes nascem em ordem
# fixa e são travados por id), e duas aberturas do mesmo item no local viram
# uma abertura e um opening_exists, sem lote nem movimento sobrando da perdedora.
# Threads reais contra TEST_CITY_A (sem fixture transacional), o padrão de
# spec/commands/care_regulation/authorize_concurrency_spec.rb. O catálogo da
# plataforma não é gravado: o comando recebe itens de mentira (o lote não tem FK
# para o catálogo, que mora em outro banco).
RSpec.describe "Entrada de estoque sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:item) { Struct.new(:id, :catmat_code, :status, :dosage_form).new(SecureRandom.uuid, 9_900_777, "active", "comprimido") }

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
      location = StockLocation.create!(kind: "central", name: "Central de Corrida", updated_by_user: admin)
      { user: admin.id, location: location.id }
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

  def entry!(lot_numbers, kind: "invoice")
    lines = lot_numbers.map do |number|
      { "catalog_item_id" => item.id, "lot_number" => number, "expires_on" => (Time.zone.today + 90).iso8601, "quantity" => "10" }
    end
    Pharmacy::RecordEntry.call(location: StockLocation.find(@rows[:location]), kind: kind,
                               document: { "number" => "NF-#{SecureRandom.hex(2)}", "supplier" => "Fornecedor" },
                               items: lines, by: User.find(@rows[:user]), catalog: { item.id => item })
  rescue StandardError => e
    e
  end

  it "duas notas com os mesmos 20 lotes novos em ordem inversa terminam as duas, sem deadlock, com um lote por número" do
    3.times do |round|
      numbers = Array.new(20) { |i| format("R%d-%02d", round, i) }
      start = Queue.new
      results = Queue.new
      two = [ numbers, numbers.reverse ].map do |order|
        Thread.new do
          Thread.current.report_on_exception = false
          start.pop(timeout: 5)
          results << in_city { entry!(order) }
        end
      end
      threads.concat(two)
      2.times { start << true }
      two.each { |thread| expect(thread.join(15)).to be(thread) }
      outcomes = Array.new(2) { results.pop(timeout: 1) }
      expect(outcomes).to all(be_a(Result)), outcomes.inspect
      expect(outcomes.map(&:ok?)).to eq([ true, true ])
      in_city do
        expect(StockLot.where(lot_number: numbers).count).to eq(20)
        expect(StockMovement.joins(:stock_lot).where(stock_lots: { lot_number: numbers }).count).to eq(40)
      end
    end
  end

  # Determinístico: a primeira transação segura o lote "A" sem commitar; a nota
  # chega com [B, A] e, como os lotes novos nascem em ordem fixa (A antes de B),
  # para em A sem ter inserido B; a primeira então insere B e commita sem esperar
  # ninguém. Se a nota inserisse na ordem do pedido (B, depois A), as duas
  # ficariam esperando uma à outra: deadlock.
  it "lotes novos em ordem fixa: a nota com [B, A] espera o lote A da outra e não trava o B" do
    expires = Time.zone.today + 90
    holding = Queue.new
    first = Queue.new
    raw = ->(number) { StockLot.create!(catalog_item_id: item.id, catmat_code: item.catmat_code, lot_number: number, expires_on: expires, dispensing_unit: "comprimido", created_by_user_id: @rows[:user]) }
    threads << holder = Thread.new do
      Thread.current.report_on_exception = false
      first << in_city do
        ApplicationRecord.transaction do
          raw.call("ORD-A")
          holding << true
          wait_for_lock_wait(timeout: 8) or raise "a nota não parou no lote A"
          raw.call("ORD-B")
          :ok
        end
      rescue StandardError => e
        e
      end
    end
    holding.pop(timeout: 5) or raise "a primeira não segurou o lote A"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { entry!(%w[ORD-B ORD-A]) }
    end
    expect(holder.join(15)).to be(holder)
    expect(other.join(15)).to be(other)
    expect(first.pop(timeout: 1)).to eq(:ok)
    result = second.pop(timeout: 1)
    expect(result).to be_a(Result), result.inspect
    expect(result).to be_ok
    in_city { expect(StockLot.where(catalog_item_id: item.id).pluck(:lot_number)).to match_array(%w[ORD-A ORD-B]) }
  end

  it "duas aberturas do mesmo item no local: uma grava, a outra espera e termina em opening_exists, sem lote nem movimento sobrando" do
    holding = Queue.new
    first = Queue.new
    threads << holder = Thread.new do
      Thread.current.report_on_exception = false
      first << in_city do
        ApplicationRecord.transaction do
          result = entry!(%w[ABRE-1], kind: "opening")
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
          result
        end
      end
    end
    holding.pop(timeout: 5) or raise "a primeira abertura não gravou"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { entry!(%w[ABRE-2], kind: "opening") }
    end
    expect(wait_for_lock_wait).to be(true) # a segunda parou no índice único da abertura
    expect(other.join(0.3)).to be_nil

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a, b ]).to all(be_a(Result))
    expect(a).to be_ok
    expect([ b.reason, b.details[:path], b.details[:problems] ]).to eq([ :opening_exists, "items[0].catalog_item_id",
                                                                         [ { path: "items[0].catalog_item_id", error: "opening_exists" } ] ])
    in_city do
      expect(StockOpening.where(catalog_item_id: item.id).count).to eq(1)
      expect(StockLot.where(catalog_item_id: item.id).pluck(:lot_number)).to eq([ "ABRE-1" ])
      expect(StockMovement.where(catalog_item_id: item.id).count).to eq(1)
      expect(StockEntry.count).to eq(1)
    end
  end
end
