require "rails_helper"

# Módulo 27a, Task 11 (ADR 0045; Pharmacy::Dispense; Review Focus 2): a
# dispensação sob disputa, com threads reais contra TEST_CITY_A (sem fixture
# transacional), o padrão de transfer_concurrency_spec.rb e cancel_lock_spec.rb.
# A prova de que uma transação esperou vem de pg_stat_activity
# (wait_for_lock_wait), nunca de sleep.
#
#   1. duas dispensações do último comprimido do lote (receitas diferentes): a
#      segunda espera a trava do lote, relê o saldo e recusa; nunca negativo;
#   2. a dispensação segura a trava do documento e o ClinicalDocuments::Cancel
#      concorrente espera por ela e termina DEPOIS (a dispensação já gravada).
# O catálogo da plataforma não é gravado: o comando recebe um item de mentira
# (o lote e o item da receita não têm FK para o catálogo, que mora em outro banco).
# O caso geral (transferência × dispensação, lotes em ordem inversa) é da Task 12.
RSpec.describe "Dispensação sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:entry) do
    Struct.new(:id, :catmat_code, :status, :dosage_form, :controlled, :controlled_list, :antimicrobial)
          .new(SecureRandom.uuid, 9_900_779, "active", "comprimido", false, nil, false)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  # Receita do 19c crua (documento e item na mesma transação, como o trigger
  # exige), com o item de mentira.
  def prescription_document!(doctor, unit, n)
    attendance = consulting_attendance!(unit, citizen: verified_citizen!(n), doctor: doctor)
    started = Consultations::Start.call(attendance: attendance, by: doctor)
    raise "consulta não iniciou: #{started.reason}" if started.failure?

    consultation = started.payload[:consultation]
    ApplicationRecord.transaction do
      document = raw_document!(consultation: consultation, kind: "prescription", issue_mode: "paper",
                               content: { "items" => [], "category" => "common", "sncr" => nil })
      PrescriptionItem.create!(clinical_document: document, position: 1, medication_catalog_item_id: entry.id, catmat_code: entry.catmat_code,
                               catalog_release_id: SecureRandom.uuid, printed_description: "Item de teste", quantity: 30,
                               quantity_unit: "comprimido", route: "oral", dosage_instructions: "1 ao dia")
      document
    end
  end

  before do
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    @rows = in_city do
      @empty = empty_tables
      PharmacySetting.ensure_defaults!
      admin = staff_with("admin-corrida-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      unit = create_unit("UBS Corrida")
      unit.update!(dispenses: true)
      farmacia = StockLocation.create!(kind: "unit", name: "Farmácia da UBS Corrida", health_unit: unit, updated_by_user: admin)
      doctor = doctor!(unit)
      documents = [ prescription_document!(doctor, unit, 1), prescription_document!(doctor, unit, 2) ]
      opened = Pharmacy::RecordEntry.call(location: farmacia, kind: "opening", document: nil, by: admin, catalog: { entry.id => entry },
                                          items: [ { "catalog_item_id" => entry.id, "lot_number" => "ULTIMO-1",
                                                     "expires_on" => (Time.zone.today + 90).iso8601, "quantity" => "1" } ])
      raise opened.inspect if opened.failure?

      { admin: admin.id, doctor: doctor.id, farmacia: farmacia.id, documents: documents.map(&:id), lot: opened.payload.fetch(:movements).sole.stock_lot_id }
    end
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError, ScriptError
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

  def balance = in_city { Pharmacy::Ledger.balance(location_id: @rows[:farmacia], lot_id: @rows[:lot]) }

  # Sem in_city: quem chama já está no seu.
  def dispense!(document_id, quantity = "1")
    settings = Pharmacy::Settings.current
    document = ClinicalDocument.includes(:prescription_items, author_user: :professional).find(document_id)
    prescription = Pharmacy::Prescription.digital(document, catalog: { entry.id => entry }, settings: settings)
    Pharmacy::Dispense.call(location: StockLocation.find(@rows[:farmacia]), prescription: prescription, retention: nil,
                            by: User.find(@rows[:admin]), role: "pharmacist", catalog: { entry.id => entry }, settings: settings,
                            items: [ { "prescription_item_id" => document.prescription_items.first.id, "lot_id" => @rows[:lot], "quantity" => quantity } ])
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
  end

  def wait_until_blocked(thread)
    expect(wait_for_lock_wait).to be(true)
    expect(thread.join(0.3)).to be_nil
  end

  it "duas dispensações do último comprimido: a segunda espera o lote, relê o saldo e recusa; o saldo fica 0, nunca negativo" do
    holding = Queue.new
    first = Queue.new
    hold(holding, first) { dispense!(@rows[:documents].first) }
    holding.pop(timeout: 5) or raise "a primeira não segurou o lote"

    second = Queue.new
    threads << other = Thread.new do
      Thread.current.report_on_exception = false
      second << in_city { dispense!(@rows[:documents].last) }
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
    expect(balance).to eq(0)
    in_city do
      expect(Dispensation.count).to eq(1)
      expect(StockMovement.where(kind: "dispensing").pluck(:quantity)).to eq([ BigDecimal("-1") ])
      expect(DomainEvent.where(name: "dispensation.recorded").count).to eq(1)
    end
  end

  it "ao mesmo tempo, sem gate: uma passa, a outra recusa; o saldo fica 0" do
    start = Queue.new
    out = Queue.new
    @rows[:documents].each do |document_id|
      threads << Thread.new do
        Thread.current.report_on_exception = false
        in_city do
          start.pop(timeout: 10) or raise "timeout"
          out << dispense!(document_id)
        end
      end
    end
    2.times { start << true }
    results = [ out.pop(timeout: 10), out.pop(timeout: 10) ]
    expect(results.map { |result| result.is_a?(Result) && result.ok? ? :ok : result.try(:reason) }).to contain_exactly(:ok, :insufficient_balance)
    expect(balance).to eq(0)
  end

  it "Review Focus 2: a dispensação segura o documento; o Cancel concorrente espera a trava e termina depois" do
    holding = Queue.new
    dispensed = Queue.new
    hold(holding, dispensed) { dispense!(@rows[:documents].first) }
    holding.pop(timeout: 5) or raise "a dispensação não segurou o documento"

    cancelled = Queue.new
    threads << canceller = Thread.new do
      Thread.current.report_on_exception = false
      cancelled << in_city do
        ClinicalDocuments::Cancel.call(document_id: @rows[:documents].first, by: User.find(@rows[:doctor]), reason: "Prescrição trocada pela médica")
      end
    end
    wait_until_blocked(canceller)
    in_city { expect(ClinicalDocument.find(@rows[:documents].first).status).not_to eq("cancelled") }

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(canceller.join(10)).to be(canceller)
    expect(dispensed.pop(timeout: 1)).to be_ok
    expect(cancelled.pop(timeout: 1)).to be_ok
    in_city do
      expect(ClinicalDocument.find(@rows[:documents].first).status).to eq("cancelled")
      dispensation = Dispensation.sole
      expect(dispensation.clinical_document_id).to eq(@rows[:documents].first)
      expect(dispensation.created_at).to be < ClinicalDocument.find(@rows[:documents].first).cancelled_at
      # Depois do cancelamento, a mesma receita é recusada sem tocar o saldo.
      expect(dispense!(@rows[:documents].first).reason).to eq(:prescription_cancelled)
    end
    expect(balance).to eq(0)
  end

  # A ordem inversa: o Cancel já gravou `cancelled` e ainda não confirmou. A
  # dispensação, que leu a receita antes (não cancelada), espera a trava do
  # documento e, liberada, relê a receita cancelada: prescription_cancelled,
  # nada gravado. Sem a trava (um SELECT simples), ela veria a versão antiga e
  # o FK da dispensação só esperaria o commit: dispensaria receita cancelada.
  it "Review Focus 2, ordem inversa: o Cancel segura o documento; a dispensação espera e recusa com prescription_cancelled" do
    holding = Queue.new
    cancelled = Queue.new
    hold(holding, cancelled) do
      ClinicalDocuments::Cancel.call(document_id: @rows[:documents].first, by: User.find(@rows[:doctor]), reason: "Prescrição trocada pela médica")
    end
    holding.pop(timeout: 5) or raise "o cancelamento não segurou o documento"

    dispensed = Queue.new
    threads << dispenser = Thread.new do
      Thread.current.report_on_exception = false
      dispensed << in_city { dispense!(@rows[:documents].first) }
    end
    wait_until_blocked(dispenser)

    release << true
    expect(threads.first.join(10)).to be(threads.first)
    expect(dispenser.join(10)).to be(dispenser)
    expect(cancelled.pop(timeout: 1)).to be_ok
    result = dispensed.pop(timeout: 1)
    expect(result).to be_a(Result)
    expect([ result.reason, result.details[:problems] ]).to eq([ :prescription_cancelled, [ { path: "prescription", error: "prescription_cancelled" } ] ])
    expect(balance).to eq(1)
    in_city { expect([ Dispensation.count, StockMovement.where(kind: "dispensing").count ]).to eq([ 0, 0 ]) }
  end
end
