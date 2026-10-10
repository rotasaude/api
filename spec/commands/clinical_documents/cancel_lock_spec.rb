# spec/commands/clinical_documents/cancel_lock_spec.rb
require "rails_helper"

# Review Focus 4 (Desvio 6): cancelar enquanto o job segura o pedido de
# assinatura (FOR UPDATE), em conexões reais. O cancelamento não espera o job
# (SKIP LOCKED), nunca falha, e o pedido não fica preso em "Pendentes": o
# próximo job que o tocar o devolve ao papel com document_cancelled. Threads
# reais contra TEST_CITY_A (sem fixture transacional); a plataforma não é
# tocada (gate do prontuário por stub).
RSpec.describe "Cancelamento com o pedido travado" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  before do
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    @rows = in_city do
      @empty = empty_tables
      unit = create_unit
      doctor = doctor!(unit)
      attendance = consulting_attendance!(unit, citizen: verified_citizen!(1), doctor: doctor)
      started = Consultations::Start.call(attendance: attendance, by: doctor)
      raise "consulta não iniciou: #{started.reason}" if started.failure?

      document = raw_document!(consultation: started.payload[:consultation], issue_mode: "digital")
      { doctor: doctor, document: document, request: signature_request!(document, author: doctor) }
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

  def stored = in_city { [ ClinicalDocument.find(@rows[:document].id).status, SignatureRequest.find(@rows[:request].id).slice(:status, :reason_code) ] }

  it "não espera o job, não falha, e o job seguinte devolve o pedido ao papel" do
    holding = Queue.new
    threads << holder = Thread.new do
      in_city do
        ApplicationRecord.transaction do
          SignatureRequest.lock.find(@rows[:request].id) # o job dentro do PSC
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
        end
      end
    end
    holding.pop(timeout: 5) or raise "o job não travou o pedido"

    cancelled = Queue.new
    threads << canceller = Thread.new do
      cancelled << in_city do
        ClinicalDocuments::Cancel.call(document_id: @rows[:document].id, by: User.find(@rows[:doctor].id),
                                       reason: "Emitido para o paciente errado")
      end
    end
    expect(canceller.join(5)).to be(canceller) # terminou com o job ainda segurando o pedido
    expect(holder).to be_alive
    expect(cancelled.pop(timeout: 1)).to be_ok
    expect(stored).to eq([ "cancelled", { "status" => "pending", "reason_code" => nil } ])

    release << true
    expect(holder.join(5)).to be(holder)
    outcome = in_city { ApplicationRecord.transaction { Signatures::SignPending.call(request_id: @rows[:request].id, signer: nil) } }
    expect(outcome).to eq(:returned_to_paper)
    expect(stored).to eq([ "cancelled", { "status" => "returned_to_paper", "reason_code" => "document_cancelled" } ])
  end
end
