require "rails_helper"

# Módulo 32b, Task 10 — Review Focus 2 (ADR 0050; contrato §6; plano, Desvio
# 7): o último comprimido, duas checagens ao mesmo tempo de ITENS DIFERENTES
# (dois encontros, o mesmo medicamento: nenhuma trava da urgência as
# serializa, só a do lote). A primeira grava a administração e o movimento e
# fica parada antes do commit; a segunda leu o saldo 1 no FEFO e espera na
# trava do lote (Ledger.lock_lots!); solta a primeira, a segunda relê o saldo
# sob a trava e grava a administração sem lote, com a falta
# insufficient_balance. As duas "201", saldo 0, nunca −1.
#
# Threads reais contra TEST_CITY_A (sem fixture transacional), como
# record_administration_concurrency_spec.rb; o catálogo da plataforma não
# entra (item de mentira para a entrada do estoque). O after solta as threads
# e apaga as tabelas que estavam vazias antes do exemplo, e as linhas
# commitadas de usuário, vínculo e unidade.
RSpec.describe Urgency::DeductStock, "concorrência" do
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
                                        cns: Professionals::Cns.generate("estoque:#{tag}:#{suffix}"))
    ProfessionalLink.create!(professional: professional, health_unit_id: ids[:unit], cbo_code: cbo, started_at: Time.current,
                             started_by_user: admin)
    user
  end

  # Um encontro (paciente próprio) com a prescrição ativa de um item do medicamento.
  def prescribed_item!(tag, n, reception, doctor)
    attrs = { "full_name" => [ "Carlos Eduardo Pinto", "Marcos Vinicius Souza" ].fetch(n - 1), "birth_date" => "1980-01-0#{n}", "sex" => "male",
              "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("estoque-paciente:#{tag}:#{n}") }
    patient = Patients::CreateTyped.call(attrs: attrs, by: reception).payload.fetch(:patient)
    encounter = Urgency::Arrive.call(health_unit_id: ids[:unit], patient_id: patient.id, by: reception, waiting_room: false).payload.fetch(:encounter)
    link = Urgency::Access.physician_link(doctor, ids[:unit])
    prescription = UrgencyPrescription.create!(urgency_encounter: encounter, version: 1, status: "active", prescribed_at: 1.minute.ago,
                                               prescribed_by_user: doctor, professional_link: link, cbo_code: link.cbo_code)
    UrgencyPrescriptionItem.create!(urgency_prescription: prescription, position: 1, catalog_item_id: entry.id, catmat_code: entry.catmat_code,
                                    stock_unit: "comprimido", dose: 50, dose_unit: "mg", route: "oral", first_dose_at: Time.current.change(sec: 0),
                                    frequency_kind: "interval", interval_hours: 8).id
  end

  before do
    in_city do
      @empty = empty_tables
      PharmacySetting.ensure_defaults!
      tag = SecureRandom.hex(4)
      reception = User.create!(email_address: "recepcao-estoque-#{tag}@c.gov.br", password: "senha-segura-123")
      ids[:admin] = reception.id
      Membership.create!(user: reception, role: "citizen_verifier", granted_at: Time.current)
      unit = HealthUnit.create!(name: "UPA Estoque #{tag}", kind: "upa", dispenses: true)
      ids[:unit] = unit.id
      doctor = professional!(tag, "medico", "225125", reception) { |id| ids[:doctor] = id }
      professional!(tag, "enfermeira", "223505", reception) { |id| ids[:doc_user] = id }
      location = StockLocation.create!(kind: "unit", name: "Farmácia da UPA Estoque #{tag}", health_unit: unit, updated_by_user: reception)
      ids[:location] = location.id
      ids[:items] = Array.new(2) { |n| prescribed_item!(tag, n + 1, reception, doctor) }
      result = Pharmacy::RecordEntry.call(location: location, kind: "opening", by: reception, catalog: { entry.id => entry }, document: nil,
                                          items: [ { "catalog_item_id" => entry.id, "lot_number" => "ULTIMO-#{tag}",
                                                     "expires_on" => (Time.zone.today + 90).iso8601, "quantity" => "1" } ])
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

  def check(item_id)
    in_city do
      item = UrgencyPrescriptionItem.find(item_id)
      Urgency::RecordAdministration.call(attrs: { "prescription_item_id" => item_id, "scheduled_at" => item.first_dose_at.iso8601,
                                                  "status" => "administered" },
                                         by: User.find(ids[:doc_user]), stock: true)
    end
  end

  it "o último comprimido, duas checagens de itens diferentes ao mesmo tempo: as duas gravam, uma com o lote, a outra com insufficient_balance" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == Urgency::RecordAdministration::EVENT
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << check(ids[:items].first) })
    holding.pop(timeout: 5) or raise "a primeira checagem não chegou a gravar"

    second_result = Queue.new
    threads << other = Thread.new { second_result << check(ids[:items].second) }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera na trava do lote

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results.map(&:ok?)).to eq([ true, true ])
    expect(results.map { |r| r.payload[:shortfall]&.cause }).to eq([ nil, "insufficient_balance" ])

    in_city do
      first, second = results.map { |r| UrgencyAdministration.find(r.payload.fetch(:administration).id) }
      expect(first.stock_lot_id).to eq(ids[:lot])
      expect(second.stock_lot_id).to be_nil
      expect(second.shortfall).to have_attributes(cause: "insufficient_balance", stock_location_id: ids[:location], quantity: 1)
      expect(StockMovement.where(stock_lot_id: ids[:lot], kind: "administration").count).to eq(1)
      expect(Pharmacy::Ledger.balance(location_id: ids[:location], lot_id: ids[:lot])).to eq(0)
    end
  end
end
