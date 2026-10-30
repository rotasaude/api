require "rails_helper"

# Módulo 27a, Task 12 (ADR 0045; Review Focus 2): o estoque da farmácia sob
# disputa, com threads reais contra TEST_CITY_A (sem fixture transacional), o
# esqueleto de dispense_concurrency_spec.rb e transfer_concurrency_spec.rb. A
# prova de que uma transação esperou vem de pg_stat_activity (wait_for_lock_wait),
# nunca de sleep; as filas usam pop(timeout:).
#
# Já cobertos pela Task 11, em dispense_concurrency_spec.rb (não se repetem aqui):
#   - o último comprimido, duas dispensações ao mesmo tempo (contain_exactly(:ok,
#     :insufficient_balance), saldo 0, um movimento, um evento);
#   - a segunda espera a trava do lote enquanto a primeira não confirma.
# Daqui:
#   1. transferência × dispensação (recebimento confirmado e desfeito);
#   2. lotes em ordem inversa não travam (sem Deadlocked);
#   3. a MESMA receita contínua com lotes DIFERENTES: só a trava do documento
#      serializa as duas, e a segunda termina em too_early;
#   4. duas devoluções do mesmo item que juntas passam do dispensado.
# O catálogo da plataforma não é gravado: os comandos recebem um item de mentira
# (lote e item da receita não têm FK para o catálogo, que mora em outro banco).
RSpec.describe "Estoque da farmácia sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:entry) do
    Struct.new(:id, :catmat_code, :status, :dosage_form, :controlled, :controlled_list, :antimicrobial)
          .new(SecureRandom.uuid, 9_900_780, "active", "comprimido", false, nil, false)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  # Receita do 19c crua (documento e item na mesma transação, como o trigger
  # exige), com o item de mentira.
  def prescription_document!(n, continuous: false)
    attendance = consulting_attendance!(@unit, citizen: verified_citizen!(n), doctor: @doctor)
    started = Consultations::Start.call(attendance: attendance, by: @doctor)
    raise "consulta não iniciou: #{started.reason}" if started.failure?

    ApplicationRecord.transaction do
      document = raw_document!(consultation: started.payload[:consultation], kind: "prescription", issue_mode: "paper",
                               content: { "items" => [], "category" => "common", "sncr" => nil })
      PrescriptionItem.create!(clinical_document: document, position: 1, medication_catalog_item_id: entry.id, catmat_code: entry.catmat_code,
                               catalog_release_id: SecureRandom.uuid, printed_description: "Item de teste", quantity: 30, continuous: continuous,
                               quantity_unit: "comprimido", route: "oral", dosage_instructions: "1 ao dia")
      document
    end
  end

  # Entra `quantity` do lote `number` no local, pelo caminho real (a abertura na
  # primeira vez do item no local, depois nota).
  def stock!(location, number, quantity)
    opening = !StockOpening.exists?(stock_location_id: location.id, catalog_item_id: entry.id)
    result = Pharmacy::RecordEntry.call(location: location, kind: opening ? "opening" : "invoice", by: User.find(@ids[:admin]), catalog: { entry.id => entry },
                                        document: (opening ? nil : { "number" => "NF-#{number}", "supplier" => "Distribuidora" }),
                                        items: [ { "catalog_item_id" => entry.id, "lot_number" => number, "expires_on" => (Time.zone.today + 90).iso8601,
                                                   "quantity" => quantity } ])
    raise result.inspect if result.failure?

    result.payload.fetch(:movements).sole.stock_lot_id
  end

  before do
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    @ids = in_city do
      @empty = empty_tables
      PharmacySetting.ensure_defaults!
      admin = staff_with("admin-corrida-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      @unit = create_unit("UBS Corrida")
      @unit.update!(dispenses: true)
      @doctor = doctor!(@unit)
      central = StockLocation.create!(kind: "central", name: "Central de Corrida", updated_by_user: admin)
      farmacia = StockLocation.create!(kind: "unit", name: "Farmácia da UBS Corrida", health_unit: @unit, updated_by_user: admin)
      { admin: admin.id, central: central.id, farmacia: farmacia.id }
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

  def farmacia = StockLocation.find(@ids[:farmacia])
  def admin = User.find(@ids[:admin])
  def balance(location_id, lot_id) = in_city { Pharmacy::Ledger.balance(location_id: location_id, lot_id: lot_id) }

  # Sem in_city: quem chama já está no seu. `lines`: [ [ lot_id, quantity ] ].
  def dispense!(document_id, lines)
    settings = Pharmacy::Settings.current
    document = ClinicalDocument.includes(:prescription_items, author_user: :professional).find(document_id)
    prescription = Pharmacy::Prescription.digital(document, catalog: { entry.id => entry }, settings: settings)
    item_id = document.prescription_items.first.id
    Pharmacy::Dispense.call(location: farmacia, prescription: prescription, retention: nil, by: admin, role: "pharmacist", catalog: { entry.id => entry },
                            settings: settings,
                            items: lines.map { |lot_id, quantity| { "prescription_item_id" => item_id, "lot_id" => lot_id, "quantity" => quantity } })
  rescue StandardError => e
    e
  end

  def receive!(transfer_id, lot_id, quantity)
    Pharmacy::ReceiveTransfer.call(transfer: StockTransfer.find(transfer_id), items: [ { "lot_id" => lot_id, "quantity_received" => quantity } ], by: admin)
  rescue StandardError => e
    e
  end

  def return!(item_id, quantity)
    item = DispensationItem.includes(:dispensation, :stock_lot).find(item_id)
    Pharmacy::RecordReturn.call(location: farmacia, dispensation_item: item, quantity: quantity, reason: "Paciente devolveu o frasco fechado", by: admin)
  rescue StandardError => e
    e
  end

  # Segura o que `work` travou até `release`, sem commitar (`rollback`: desfaz
  # tudo depois do gate); devolve o resultado pela fila `out`.
  def hold(holding, out, rollback: false, &work)
    threads << Thread.new do
      Thread.current.report_on_exception = false
      out << in_city do
        result = nil
        ApplicationRecord.transaction do
          result = work.call
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
          raise ActiveRecord::Rollback if rollback
        end
        result
      end
    end
    holding.pop(timeout: 5) or raise "a primeira transação não segurou as travas"
  end

  def run_in_thread(out, &work)
    threads << thread = Thread.new do
      Thread.current.report_on_exception = false
      out << in_city(&work)
    end
    thread
  end

  # A sessão que espera o lock, a query dela e a prova de que ainda não terminou.
  def waiting_queries
    in_city do
      ApplicationRecord.connection.select_values("SELECT query FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'")
    end
  end

  def wait_until_blocked(thread)
    expect(wait_for_lock_wait).to be(true)
    expect(thread.join(0.3)).to be_nil
  end

  def finish(*pending)
    release << true
    ([ threads.first ] + pending).each { |thread| expect(thread.join(10)).to be(thread) }
  end

  describe "transferência × dispensação (UBS com saldo 0 e transferência sent de 10 do mesmo lote)" do
    before do
      @transfer = in_city do
        lot = stock!(StockLocation.find(@ids[:central]), "TRF-1", "10")
        sent = Pharmacy::SendTransfer.call(from: StockLocation.find(@ids[:central]), to: farmacia, items: [ { "lot_id" => lot, "quantity" => "10" } ], by: admin)
        raise sent.inspect if sent.failure?

        { id: sent.payload.fetch(:transfer).id, lot: lot, document: prescription_document!(1).id }
      end
    end

    it "o recebimento segura o lote depois do transfer_in; a dispensação de 4 espera a trava do lote e, liberada, passa; o saldo final é 6" do
      received = Queue.new
      hold(Queue.new, received) { receive!(@transfer[:id], @transfer[:lot], "10") }

      dispensed = Queue.new
      dispenser = run_in_thread(dispensed) { dispense!(@transfer[:document], [ [ @transfer[:lot], "4" ] ]) }
      wait_until_blocked(dispenser)
      expect(balance(@ids[:farmacia], @transfer[:lot])).to eq(0) # o transfer_in ainda não foi confirmado

      finish(dispenser)
      expect(received.pop(timeout: 1)).to be_ok
      expect(dispensed.pop(timeout: 1)).to be_ok
      expect(balance(@ids[:farmacia], @transfer[:lot])).to eq(6)
      in_city do
        expect(StockTransfer.sole.status).to eq("received")
        expect(StockMovement.where(stock_location_id: @ids[:farmacia]).order(:recorded_at).pluck(:kind, :quantity))
          .to eq([ [ "transfer_in", BigDecimal("10") ], [ "dispensing", BigDecimal("-4") ] ])
        expect(DomainEvent.where(name: "dispensation.recorded").count).to eq(1)
      end
    end

    it "o inverso: o recebimento é desfeito depois do gate; a dispensação que esperava relê o saldo 0 e leva insufficient_balance" do
      received = Queue.new
      hold(Queue.new, received, rollback: true) { receive!(@transfer[:id], @transfer[:lot], "10") }

      dispensed = Queue.new
      dispenser = run_in_thread(dispensed) { dispense!(@transfer[:document], [ [ @transfer[:lot], "4" ] ]) }
      wait_until_blocked(dispenser)

      finish(dispenser)
      expect(received.pop(timeout: 1)).to be_ok # o comando terminou; o desfazer foi da transação de fora
      result = dispensed.pop(timeout: 1)
      expect(result).to be_a(Result)
      expect([ result.reason, result.details[:path], result.details[:problems] ])
        .to eq([ :insufficient_balance, "items[0].quantity", [ { path: "items[0].quantity", error: "insufficient_balance" } ] ])
      expect(balance(@ids[:farmacia], @transfer[:lot])).to eq(0)
      in_city do
        expect(StockTransfer.sole.status).to eq("sent")
        expect([ Dispensation.count, StockMovement.where(kind: %w[dispensing transfer_in]).count ]).to eq([ 0, 0 ])
      end
    end
  end

  # A trava dos lotes é em ordem de id, não na ordem das linhas: A pede [1, 2] e
  # B pede [2, 1] e nenhuma fica com um lote esperando o do outro.
  it "lotes em ordem inversa não travam: as duas dispensações terminam ok em menos de 5 s, nenhuma Deadlocked" do
    lots, documents = in_city do
      [ [ stock!(farmacia, "ORDEM-1", "100"), stock!(farmacia, "ORDEM-2", "100") ], [ prescription_document!(1).id, prescription_document!(2).id ] ]
    end
    rounds = 10
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rounds.times do
      start = Queue.new
      out = Queue.new
      pair = [ [ documents.first, lots ], [ documents.last, lots.reverse ] ].map do |document_id, order|
        threads << thread = Thread.new do
          Thread.current.report_on_exception = false
          in_city do
            start.pop(timeout: 10) or raise "timeout"
            out << dispense!(document_id, order.map { |lot_id| [ lot_id, "1" ] })
          end
        end
        thread
      end
      2.times { start << true }
      pair.each { |thread| expect(thread.join(10)).to be(thread) }
      results = [ out.pop(timeout: 1), out.pop(timeout: 1) ]
      expect(results.map { |result| result.class }).to eq([ Result, Result ]), results.inspect
      expect(results.map(&:ok?)).to eq([ true, true ])
    end
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5 * rounds
    expect(lots.map { |lot_id| balance(@ids[:farmacia], lot_id) }).to eq([ 100 - 2 * rounds, 100 - 2 * rounds ])
    in_city { expect(Dispensation.count).to eq(2 * rounds) }
  end

  # Lotes diferentes não se travam entre si: só o documento da receita serializa
  # as duas dispensações. A segunda, que leu a receita antes da primeira gravar,
  # tem de reler o resumo do que já saiu DEPOIS de travar o documento; lido
  # antes, ela dispensaria de novo no mesmo dia (uso contínuo).
  it "a MESMA receita contínua, lotes diferentes: a segunda espera a trava do documento e termina em too_early" do
    lot_a, lot_b, document = in_city do
      [ stock!(farmacia, "CONT-A", "100"), stock!(farmacia, "CONT-B", "100"), prescription_document!(1, continuous: true).id ]
    end
    first = Queue.new
    hold(Queue.new, first) { dispense!(document, [ [ lot_a, "30" ] ]) }

    second = Queue.new
    other = run_in_thread(second) { dispense!(document, [ [ lot_b, "30" ] ]) }
    wait_until_blocked(other)
    expect(waiting_queries.sole).to include('"clinical_documents"') # a espera é do documento, não de um lote

    finish(other)
    expect(first.pop(timeout: 1)).to be_ok
    result = second.pop(timeout: 1)
    expect(result).to be_a(Result)
    next_allowed = (Time.zone.today + 25).iso8601
    expect([ result.reason, result.details[:path], result.details[:next_allowed_on], result.details[:problems] ])
      .to eq([ :too_early, "items[0]", next_allowed, [ { path: "items[0]", error: "too_early", next_allowed_on: next_allowed } ] ])
    expect([ balance(@ids[:farmacia], lot_a), balance(@ids[:farmacia], lot_b) ]).to eq([ 70, 100 ])
    in_city do
      expect(Dispensation.count).to eq(1)
      expect(StockMovement.where(kind: "dispensing").pluck(:stock_lot_id, :quantity)).to eq([ [ lot_a, BigDecimal("-30") ] ])
      expect(DomainEvent.where(name: "dispensation.recorded").count).to eq(1)
    end
  end

  # Devolver 6 duas vezes de um item dispensado de 10: cada uma, olhando sozinha,
  # cabe (0 + 6 <= 10); juntas passam. O que decide é o `exceeds?` relido sob a
  # trava do lote, com a primeira já gravada.
  it "duas devoluções do mesmo item que juntas passam do dispensado: uma passa, a outra recebe return_exceeds; saldo e devolvido certos" do
    lot, item_id = in_city do
      lot_id = stock!(farmacia, "DEV-1", "100")
      dispensed = dispense!(prescription_document!(1).id, [ [ lot_id, "10" ] ])
      raise dispensed.inspect unless dispensed.is_a?(Result) && dispensed.ok?

      [ lot_id, dispensed.payload.fetch(:dispensation).items.sole.id ]
    end
    expect(balance(@ids[:farmacia], lot)).to eq(90)

    first = Queue.new
    hold(Queue.new, first) { return!(item_id, "6") }

    second = Queue.new
    other = run_in_thread(second) { return!(item_id, "6") }
    wait_until_blocked(other)

    finish(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a, b ]).to all(be_a(Result))
    expect(a).to be_ok
    expect([ b.reason, b.details[:path], b.details[:problems] ]).to eq([ :return_exceeds, "quantity", [ { path: "quantity", error: "return_exceeds" } ] ])
    expect(balance(@ids[:farmacia], lot)).to eq(96)
    in_city do
      expect(Pharmacy::Dispensed.returned_totals([ item_id ])).to eq(item_id => BigDecimal("6"))
      expect(StockMovement.where(kind: "return").pluck(:quantity)).to eq([ BigDecimal("6") ])
      expect(DomainEvent.where(name: "dispensation.returned").count).to eq(1)
    end
  end
end
