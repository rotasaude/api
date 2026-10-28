require "rails_helper"

# Módulo 25, Task 9 (ADR 0043): o consumidor da rede de segurança.
RSpec.describe Surveillance::SafetyNetJob do
  include ActiveJob::TestHelper

  before { surveillance_city! }
  after { Current.reset }

  let(:unit) { HealthUnit.create!(name: "UBS Rede #{SecureRandom.hex(2)}", kind: "ubs") }
  let(:doctor) { doctor!(unit) }
  let(:dengue_add) { [ { "terminology" => "cid10", "code" => "A90", "action" => "add" } ] }

  def consume!(event)
    described_class.perform_now(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
  end

  def event(name) = DomainEvent.where(name: name).order(:occurred_at, :created_at).last

  it "está ligado aos dois eventos do 19a" do
    %w[consultation.finalized consultation.addendum_added].each do |name|
      expect(DomainEvents.registry[name].map(&:job)).to include("Surveillance::SafetyNetJob")
    end
  end

  it "consome a finalização: uma possible; interruptor desligado: nada" do
    c = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(61), "evaluated_problems" => dengue_add)
    Platform::Features.set!(city: Current.city, key: "surveillance", enabled: false, maintainer: ledi_maintainer!)
    consume!(event("consultation.finalized"))
    expect(DiseaseNotification.count).to eq(0)

    Platform::Features.set!(city: Current.city, key: "surveillance", enabled: true, maintainer: ledi_maintainer!)
    other = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(62), "evaluated_problems" => dengue_add)
    consume!(event("consultation.finalized"))
    expect(DiseaseNotification.pluck(:consultation_id, :origin, :status)).to eq([ [ other.id, "safety_net", "possible" ] ])
    expect(DiseaseNotification.where(consultation_id: c.id)).to be_empty
  end

  it "o mesmo adendo redespachado (mesmo evento) não gera outra, nem depois de dispensada a primeira" do
    c = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(63),
                                "evaluated_problems" => [ { "terminology" => "ciap2", "code" => "T90", "action" => "add" } ])
    consume!(event("consultation.finalized"))
    expect(DiseaseNotification.count).to eq(0)

    added = Consultations::AddAddendum.call(consultation: c, by: doctor, reason: "Resultado do exame chegou", text: "NS1 reagente.",
                                            changes: { "evaluated_problems" => dengue_add })
    expect(added).to be_ok
    addendum_event = event("consultation.addendum_added")
    expect(addendum_event.payload).to eq("consultation_id" => c.id, "addendum_id" => added.payload[:addendum].id)
    consume!(addendum_event)
    possible = DiseaseNotification.sole
    expect([ possible.status, possible.addendum_id ]).to eq([ "possible", added.payload[:addendum].id ])

    # Dispensada, a possible não bloqueia mais: só o dedup do consumidor segura o redespacho.
    possible.update!(status: "dismissed", dismissed_at: Time.current)
    consume!(addendum_event)
    expect(DiseaseNotification.count).to eq(1)
  end
end

# Review Focus 2 (Desvio 13): "Notificar suspeita" (NotifyFromConsultation)
# contra a rede de segurança na MESMA consulta finalizada, em conexões reais.
# Uma segura a consulta até a outra estar esperando; terminam com uma
# notificação aberta, sem exceção (a perdedora vê already_notified). Se a rede
# não travasse a consulta antes do paciente, ela seguraria o paciente e a FK do
# INSERT esperaria o KEY SHARE da consulta, enquanto o POST, com a consulta,
# esperaria o paciente: deadlock. Threads reais contra TEST_CITY_A (sem fixture
# transacional); a plataforma é só lida (termos, lista e portões por stub),
# nada é gravado nela.
RSpec.describe "Rede de segurança × Notificar suspeita sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # Tabelas da cidade vazias antes do exemplo: o que o exemplo commitou nelas sai no after.
  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  let(:disease) do
    Surveillance::Diseases.from_local(LocalNotifiableDisease.new(code: "local_corrida_rede", name: "Corrida", deadline: "weekly",
                                                                  cid10: [ "A90" ], ciap2: [], repeat_after_days: 30, active: true))
  end

  before do
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    allow(Surveillance::Diseases).to receive(:all).and_return([ disease ])
    release_id = SecureRandom.uuid
    allow(ClinicalTerms).to receive(:find) do |terminology, code|
      ClinicalTerms::Code.new(terminology: terminology.to_s, code: code, label: "Dengue", release_id: release_id) if code == "A90"
    end
    allow(ClinicalTerms).to receive(:cid10_sex).and_return(nil)
    @rows = in_city do
      @empty = empty_tables
      @since = ApplicationRecord.connection.select_value("SELECT clock_timestamp()")
      unit = create_unit("UBS Corrida Rede")
      doctor = doctor!(unit)
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(71), "exam_requests" => [],
                                             "evaluated_problems" => [ { "terminology" => "cid10", "code" => "A90", "action" => "add" } ])
      { doctor_id: doctor.id, consultation_id: consultation.id, patient_id: consultation.patient_id }
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
        # Tabelas que já tinham linhas antes: só o que este exemplo commitou.
        DomainEvent.where(created_at: @since..).delete_all unless @empty.to_a.include?("domain_events")
      end
    end
  end

  def consultation = Consultation.find(@rows[:consultation_id])

  def notify!
    Surveillance::NotifyFromConsultation.call(consultation: consultation, disease_code: disease.code, symptoms_on: nil,
                                              by: User.find(@rows[:doctor_id]))
  rescue StandardError => e
    e
  end

  def safety_net!
    Surveillance::SafetyNet.call(consultation: consultation)
  rescue StandardError => e
    e
  end

  # A primeira segura a consulta (FOR UPDATE) até a segunda estar esperando um lock.
  def race(first_call, second_call)
    holding = Queue.new
    first = Queue.new
    threads << holder = Thread.new do
      first << in_city do
        ApplicationRecord.transaction do
          Consultation.lock.find(@rows[:consultation_id])
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
          send(first_call)
        end
      end
    end
    holding.pop(timeout: 5) or raise "a primeira não travou a consulta"

    second = Queue.new
    threads << other = Thread.new { second << in_city { send(second_call) } }
    expect(in_city { wait_for_lock_wait }).to be(true)

    release << true
    expect(holder.join(10)).to be(holder)
    expect(other.join(10)).to be(other)
    [ first.pop(timeout: 1), second.pop(timeout: 1) ]
  end

  def open_notifications = in_city { DiseaseNotification.open_notifications.where(patient_id: @rows[:patient_id]).pluck(:origin, :status) }

  it "Notificar suspeita segura a consulta; a rede espera e não cria nada" do
    notified, net = race(:notify!, :safety_net!)
    expect(notified).to be_a(Result).and(be_ok)
    expect(net).to eq(created: 0)
    expect(open_notifications).to eq([ %w[consultation notified] ])
  end

  it "a rede segura a consulta; Notificar suspeita espera e vê already_notified" do
    net, notified = race(:safety_net!, :notify!)
    expect(net).to eq(created: 1)
    expect(notified).to be_a(Result)
    expect(notified.reason).to eq(:already_notified)
    expect(open_notifications).to eq([ %w[safety_net possible] ])
  end
end
