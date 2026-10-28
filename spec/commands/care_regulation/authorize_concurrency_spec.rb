require "rails_helper"

# Módulo 26a, Task 8 (ADR 0044; plano do api, Desvio 3 e 6): duas autorizações
# disputando a última vaga. A cota usada é contada SOB a trava da oferta (FOR
# UPDATE): quem chega depois espera a primeira commitar e vê a vaga gasta —
# uma autorização e um quota_exhausted, nunca duas. Threads reais contra
# TEST_CITY_A (sem fixture transacional), o padrão de
# spec/models/health_unit_lock_spec.rb e de
# spec/commands/clinical_documents/issue_concurrency_spec.rb: a plataforma só é
# lida (interruptores e terminologia por stub), nada é gravado nela; o que o
# exemplo commitou na cidade sai no after.
RSpec.describe "Autorização da regulação sob disputa" do
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:now) { Time.zone.local(2026, 10, 28, 10, 0) }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # Tabelas da cidade vazias antes do exemplo: o que o exemplo commitou nelas
  # sai no after.
  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  # Pedido `pending` pelo caminho real (rascunho na consulta e promoção), sem
  # a finalização inteira: Promote dentro de uma transação, como na Finalize.
  def pending_request!(unit:, doctor:, n:, at:)
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(n))
    saved = CareRegulation::SaveDraft.call(consultation: consultation, attrs: RegulationHelpers::REGULATION_DEFAULTS, by: doctor)
    raise "rascunho recusado: #{saved.reason}" if saved.failure?

    ApplicationRecord.transaction { CareRegulation::Promote.call(consultation: consultation, by: doctor, now: at) }
    saved.payload.fetch(:request).reload.tap { |r| raise "não promovido" unless r.status == "pending" }
  end

  before do
    travel_to now
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    allow(CareRegulation::Diagnosis).to receive(:check).and_return(Result.ok(cid10: "I10", ciap2: nil))
    @rows = in_city do
      @empty = empty_tables
      unit = create_unit("UBS Corrida Regulação")
      doctor = doctor!(unit)
      older = pending_request!(unit: unit, doctor: doctor, n: 1, at: now - 3.days)
      newer = pending_request!(unit: unit, doctor: doctor, n: 2, at: now - 1.day)
      offer = offer!(provider: external_provider!, quantity: 1)
      { regulator: care_regulator!, older: older.id, newer: newer.id, offer: offer.id }
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
    travel_back
  end

  def authorize!(id, **over)
    request = RegulationRequest.find(id)
    CareRegulation::Authorize.call(request: request, offer_id: @rows[:offer], version: request.version,
                                   by: User.find(@rows[:regulator].id), **over)
  rescue StandardError => e
    e
  end

  it "duas autorizações na última vaga: uma autoriza, a outra espera a trava e termina em quota_exhausted" do
    holding = Queue.new
    first = Queue.new
    threads << holder = Thread.new do
      first << in_city do
        ApplicationRecord.transaction do
          CareOffer.lock.find(@rows[:offer])
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
          authorize!(@rows[:older])
        end
      end
    end
    holding.pop(timeout: 5) or raise "a primeira não travou a oferta"

    second = Queue.new
    threads << other = Thread.new do
      second << in_city { authorize!(@rows[:newer], skip_reason: "Paciente com cirurgia já marcada no prestador") }
    end
    expect(other.join(0.5)).to be_nil # bloqueada pelo FOR UPDATE da oferta

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a, b ]).to all(be_a(Result))
    expect(a).to be_ok
    expect(b.reason).to eq(:quota_exhausted)
    in_city do
      expect(CareRegulation::Quota.used([ @rows[:offer] ])).to eq(@rows[:offer] => 1)
      expect(RegulationRequest.where(id: [ @rows[:older], @rows[:newer] ]).pluck(:id, :status).to_h)
        .to eq(@rows[:older] => "authorized", @rows[:newer] => "pending")
      expect(RegulationAuthorization.where(care_offer_id: @rows[:offer]).count).to eq(1)
    end
  end
end
