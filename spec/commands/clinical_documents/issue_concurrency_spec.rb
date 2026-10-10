# spec/commands/clinical_documents/issue_concurrency_spec.rb
require "rails_helper"

# Task 12/15 (Review Focus 2): "dois cliques em Emitir receita" com item de uso
# contínuo em texto livre (sem índice único — a comparação é em Ruby, sobre o
# texto cifrado). A emissão trava o paciente antes de aplicar os eventos: a
# segunda espera a primeira commitar e vê o medicamento já ativo. Dois
# documentos podem nascer; a lista fica com UM ativo (a segunda vira changed,
# ou nada se a posologia é a mesma) — nunca duplicado, nunca 500. Threads reais
# contra TEST_CITY_A (sem fixture transacional); a plataforma é só lida
# (catálogo vazio, listas Anvisa vazias por stub), nada é gravado nela.
RSpec.describe "Emissão de receita sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # Tabelas da cidade vazias antes do exemplo: o que o exemplo commitou nelas
  # sai no after (o banco de teste da branch só tem linhas commitadas por specs
  # como esta).
  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  before do
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    allow(Medications::Search).to receive(:available?).and_return(true)
    allow(Medications::Substances).to receive(:matcher).and_return(Medications::Substances::Matcher.new(antimicrobials: [], controlled: {}))
    @rows = in_city do
      @empty = empty_tables
      unit = create_unit
      doctor = doctor!(unit)
      attendance = consulting_attendance!(unit, citizen: verified_citizen!(1), doctor: doctor)
      started = Consultations::Start.call(attendance: attendance, by: doctor)
      raise "consulta não iniciou: #{started.reason}" if started.failure?

      { doctor: doctor, consultation: started.payload[:consultation] }
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

  def content(dosage)
    { "items" => [ { "free_text" => "Chá de camomila", "quantity" => 1, "quantity_unit" => "caixa", "route" => "oral",
                     "dosage_instructions" => dosage, "continuous" => true } ] }
  end

  def issue(dosage)
    in_city do
      ClinicalDocuments::Issue.call(kind: "prescription", content: content(dosage), by: User.find(@rows[:doctor].id),
                                    consultation: Consultation.find(@rows[:consultation].id))
    end
  end

  it "a segunda espera o paciente travado e muda o medicamento já ativo, sem duplicar" do
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "clinical_document.issued"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first = Queue.new
    threads << (holder = Thread.new { first << issue("1 sachê à noite") })
    holding.pop(timeout: 5) or raise "a primeira não chegou ao fim da emissão"

    second = Queue.new
    threads << other = Thread.new { second << issue("1 sachê de 12/12h") }
    expect(wait_for_lock_wait).to be(true) # a segunda espera o lock do paciente

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a.ok?, b.ok? ]).to eq([ true, true ])
    expect(b.payload[:document].id).not_to eq(a.payload[:document].id)
    in_city do
      medication = PatientMedication.sole
      expect(medication).to have_attributes(status: "active", dosage_summary: "1 sachê de 12/12h")
      expect(medication.events.order(:created_at).map { |event| [ event.kind, event.clinical_document_id ] })
        .to eq([ [ "added", a.payload[:document].id ], [ "changed", b.payload[:document].id ] ])
    end
  end
end
