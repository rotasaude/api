require "rails_helper"

# Módulo 32b, Task 12 — Review Focus 3 (ADR 0050; contrato §4, §5 e §6): o
# desfecho e a checagem da medicação do MESMO encontro ao mesmo tempo, com a
# baixa do FEFO ligada (o lote entra). O desfecho trava atendimento →
# encontro → estadia → prescrição (FOR UPDATE); a checagem, atendimento →
# encontro → prescrição (FOR SHARE) → itens → lotes → local. As duas se
# serializam no atendimento: ou a checagem commita antes (201, a
# administração e o movimento ficam, e o desfecho fecha depois) ou vem
# depois (409 encounter_closed, nada gravado, o saldo intacto). Nunca
# deadlock.
#
# Threads reais contra TEST_CITY_A (sem fixture transacional), como
# deduct_stock_concurrency_spec.rb; o catálogo da plataforma não entra (item
# de mentira para a entrada do estoque). O after solta as threads e apaga as
# tabelas que estavam vazias antes do exemplo, e as linhas commitadas de
# usuário, vínculo e unidade.
RSpec.describe Urgency::RecordOutcome, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:entry) do
    Struct.new(:id, :catmat_code, :status, :dosage_form, :controlled, :controlled_list, :antimicrobial)
          .new(SecureRandom.uuid, 268_856, "active", "comprimido", false, nil, false)
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  def professional!(tag, suffix, cbo, admin)
    user = User.create!(email_address: "#{suffix}-#{tag}@c.gov.br", password: "senha-segura-123")
    yield user.id
    Membership.create!(user: user, role: "health_professional", granted_at: Time.current)
    professional = Professional.create!(user: user, professional_name: "Profissional #{suffix}", council: "COREN", council_state: "PR",
                                        registration_number: "#{tag.to_i(16).to_s[0, 6]}#{suffix.length}",
                                        cns: Professionals::Cns.generate("desfecho:#{tag}:#{suffix}"))
    ProfessionalLink.create!(professional: professional, health_unit_id: ids[:unit], cbo_code: cbo, started_at: Time.current,
                             started_by_user: admin)
    user
  end

  before do
    in_city do
      @empty = empty_tables
      PharmacySetting.ensure_defaults!
      tag = SecureRandom.hex(4)
      reception = User.create!(email_address: "recepcao-desfecho-#{tag}@c.gov.br", password: "senha-segura-123")
      ids[:admin] = reception.id
      Membership.create!(user: reception, role: "citizen_verifier", granted_at: Time.current)
      unit = HealthUnit.create!(name: "UPA Desfecho #{tag}", kind: "upa", dispenses: true)
      ids[:unit] = unit.id
      doctor = professional!(tag, "medico", "225125", reception) { |id| ids[:doctor] = id }
      nurse = professional!(tag, "enfermeira", "223505", reception) { |id| ids[:doc_user] = id }
      location = StockLocation.create!(kind: "unit", name: "Farmácia da UPA Desfecho #{tag}", health_unit: unit, updated_by_user: reception)
      ids[:location] = location.id

      attrs = { "full_name" => "Carlos Eduardo Pinto", "birth_date" => "1980-01-01", "sex" => "male",
                "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("desfecho-paciente:#{tag}") }
      patient = Patients::CreateTyped.call(attrs: attrs, by: reception).payload.fetch(:patient)
      encounter = Urgency::Arrive.call(health_unit_id: unit.id, patient_id: patient.id, by: reception, waiting_room: false).payload.fetch(:encounter)
      ids[:encounter] = encounter.id
      classified = Urgency::Classify.call(encounter: encounter, by: nurse,
                                          attrs: { "complaint" => "Dor no peito", "vital_signs" => {}, "pain_scale" => 0,
                                                   "color" => "green", "justification" => "Avaliação de enfermagem na porta" })
      raise "classificação recusada: #{classified.reason}" if classified.failure?

      called = Attendances::Call.call(attendance: encounter.attendance.reload, health_unit_id: unit.id, by: doctor)
      raise "chamada recusada: #{called.reason}" if called.failure?

      bed = UrgencyBed.create!(health_unit: unit, label: "OBS 01", updated_by_user: reception)
      started = Urgency::StartObservation.call(encounter: encounter.reload, bed_id: bed.id, by: doctor)
      raise "entrada no leito recusada: #{started.reason}" if started.failure?

      ids[:stay] = started.payload.fetch(:stay).id
      link = Urgency::Access.physician_link(doctor, unit.id)
      prescription = UrgencyPrescription.create!(urgency_encounter: encounter, version: 1, status: "active", prescribed_at: 1.minute.ago,
                                                 prescribed_by_user: doctor, professional_link: link, cbo_code: link.cbo_code)
      ids[:prescription] = prescription.id
      ids[:item] = UrgencyPrescriptionItem.create!(urgency_prescription: prescription, position: 1, catalog_item_id: entry.id,
                                                   catmat_code: entry.catmat_code, stock_unit: "comprimido", dose: 50, dose_unit: "mg",
                                                   route: "oral", first_dose_at: Time.current.change(sec: 0),
                                                   frequency_kind: "interval", interval_hours: 8).id
      result = Pharmacy::RecordEntry.call(location: location, kind: "opening", by: reception, catalog: { entry.id => entry }, document: nil,
                                          items: [ { "catalog_item_id" => entry.id, "lot_number" => "FEFO-#{tag}",
                                                     "expires_on" => (Time.zone.today + 90).iso8601, "quantity" => "5" } ])
      raise result.inspect if result.failure?

      ids[:lot] = result.payload.fetch(:movements).sole.stock_lot_id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError, ScriptError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        @empty.to_a.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit, :doctor, :doc_user))
  end

  # A exceção da thread (deadlock inclusive) volta como valor, para o expect.
  def capture
    yield
  rescue StandardError => e
    e
  end

  def check
    capture do
      in_city do
        item = UrgencyPrescriptionItem.find(ids[:item])
        Urgency::RecordAdministration.call(attrs: { "prescription_item_id" => item.id, "scheduled_at" => item.first_dose_at.iso8601,
                                                    "status" => "administered" },
                                           by: User.find(ids[:doc_user]), stock: true)
      end
    end
  end

  def outcome
    capture do
      in_city do
        described_class.call(encounter: UrgencyEncounter.find(ids[:encounter]), attrs: { "kind" => "left_without_care" },
                             by: User.find(ids[:admin]))
      end
    end
  end

  # A primeira (`first`) grava, publica `event` e fica parada antes do
  # commit; a segunda tem de esperar na trava do atendimento.
  # -> [resultado da primeira, resultado da segunda]
  def race(first, event, second)
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == event
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << send(first) })
    holding.pop(timeout: 5) or raise "a primeira não chegou a gravar"

    second_result = Queue.new
    threads << other = Thread.new { second_result << send(second) }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera na trava do atendimento

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results).to all(be_a(Result)) # nenhuma exceção (PG::TRDeadlockDetected inclusive)
    results
  end

  def balance = in_city { Pharmacy::Ledger.balance(location_id: ids[:location], lot_id: ids[:lot]) }

  it "a checagem chega antes: 201 com o lote, e o desfecho fecha a estadia e encerra a prescrição depois" do
    checked, closed = race(:check, Urgency::RecordAdministration::EVENT, :outcome)
    expect([ checked.ok?, closed.ok? ]).to eq([ true, true ])
    in_city do
      administration = UrgencyAdministration.find(checked.payload.fetch(:administration).id)
      expect(administration.stock_lot_id).to eq(ids[:lot])
      expect(UrgencyBedStay.find(ids[:stay])).to have_attributes(end_kind: "outcome", ended_by_user_id: ids[:admin])
      expect(UrgencyPrescription.find(ids[:prescription]).status).to eq("ended")
      expect(UrgencyEncounter.find(ids[:encounter]).state).to eq("closed")
    end
    expect(balance).to eq(4)
  end

  it "o desfecho chega antes: a checagem vem depois e é 409 encounter_closed, sem administração nem baixa" do
    closed, checked = race(:outcome, described_class::EVENT, :check)
    expect(closed).to be_ok
    expect(checked.reason).to eq(:encounter_closed)
    in_city do
      expect(UrgencyAdministration.where(urgency_encounter_id: ids[:encounter])).to be_empty
      expect(UrgencyBedStay.find(ids[:stay])).to have_attributes(end_kind: "outcome")
      expect(UrgencyPrescription.find(ids[:prescription]).status).to eq("ended")
    end
    expect(balance).to eq(5)
  end
end
