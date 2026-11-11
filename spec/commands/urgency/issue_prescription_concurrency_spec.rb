require "rails_helper"

# Q16 (revisão da Task 6 do dashboard; plano do 32b, §5): dois médicos com a
# mesma tela da prescrição (expected_active_id = a v1). O primeiro emite a v2 e
# fica parado depois de publicar o evento (antes do commit); o segundo espera a
# trava do encontro; solta o primeiro, o segundo relê, vê que a ativa já não é a
# v1 e recebe prescription_changed, sem superseder nada. Threads reais contra
# TEST_CITY_A (sem fixture transacional), como start_observation_concurrency_spec.rb;
# o after solta as threads e apaga tudo o que commitou.
RSpec.describe Urgency::IssuePrescription, "concorrência" do
  self.use_transactional_tests = false

  Drug = Struct.new(:id, :catmat_code, :controlled_list, :dosage_form)

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:drug) { Drug.new(SecureRandom.uuid, 268_856, nil, "comprimido") }

  def professional!(tag, suffix, cbo, admin)
    user = User.create!(email_address: "#{suffix}-#{tag}@c.gov.br", password: "senha-segura-123")
    yield user.id
    Membership.create!(user: user, role: "health_professional", granted_at: Time.current)
    professional = Professional.create!(user: user, professional_name: "Profissional #{suffix}", council: "CRM", council_state: "PR",
                                        registration_number: "#{tag.to_i(16).to_s[0, 6]}#{suffix.length}",
                                        cns: Professionals::Cns.generate("rx:#{tag}:#{suffix}"))
    ProfessionalLink.create!(professional: professional, health_unit_id: ids[:unit], cbo_code: cbo, started_at: Time.current,
                             started_by_user: admin)
    user
  end

  before do
    allow(ClinicalRecord::Gate).to receive(:usable?).and_return(true)
    allow(Urgency::Gate).to receive(:usable?).and_return(true)
    in_city do
      tag = SecureRandom.hex(4)
      # Cada id entra em `ids` assim que a linha nasce: se o before falhar no
      # meio, o after ainda limpa o que já foi commitado.
      reception = User.create!(email_address: "recepcao-rx-#{tag}@c.gov.br", password: "senha-segura-123")
      ids[:admin] = reception.id
      Membership.create!(user: reception, role: "citizen_verifier", granted_at: Time.current)
      ids[:unit] = HealthUnit.create!(name: "UPA Prescricao #{tag}", kind: "upa").id
      doctor = professional!(tag, "medico", "225125", reception) { |id| ids[:doctor] = id }
      nurse = professional!(tag, "enfermeira", "223505", reception) { |id| ids[:nurse] = id }
      professional!(tag, "doutora", "225125", reception) { |id| ids[:second_doctor] = id }
      ids[:patients] = []
      ids[:encounters] = []
      ids[:attendances] = []
      1.times do |n|
        attrs = { "full_name" => "Carlos Eduardo Pinto", "birth_date" => "1980-01-0#{n + 1}", "sex" => "male",
                  "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("rx-paciente:#{tag}:#{n}") }
        patient = Patients::CreateTyped.call(attrs: attrs, by: reception).payload.fetch(:patient)
        ids[:patients] << patient.id
        encounter = Urgency::Arrive.call(health_unit_id: ids[:unit], patient_id: patient.id, by: reception, waiting_room: false)
                                   .payload.fetch(:encounter)
        ids[:encounters] << encounter.id
        ids[:attendances] << encounter.attendance_id
        classified = Urgency::Classify.call(encounter: encounter, by: nurse,
                                            attrs: { "complaint" => "Dor no peito", "vital_signs" => {}, "pain_scale" => 0,
                                                     "color" => "green", "justification" => "Avaliação de enfermagem na porta" })
        raise "classificação recusada: #{classified.reason}" if classified.failure?

        called = Attendances::Call.call(attendance: encounter.attendance.reload, health_unit_id: ids[:unit], by: doctor)
        raise "chamada recusada: #{called.reason}" if called.failure?

        started = Consultations::Start.call(attendance: encounter.attendance.reload, by: doctor, kind: nil, city: TEST_CITY_A)
        raise "consulta recusada: #{started.reason}" if started.failure?

        ids[:consultation] = started.payload.fetch(:consultation).id
      end
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        patient_ids = ids.fetch(:patients, [])
        encounter_ids = ids.fetch(:encounters, [])
        attendance_ids = ids.fetch(:attendances, [])
        DomainEvent.where("payload->>'patient_id' IN (?) OR payload->>'encounter_id' IN (?) OR payload->>'attendance_id' IN (?)",
                          patient_ids.presence || [ "" ], encounter_ids.presence || [ "" ], attendance_ids.presence || [ "" ]).delete_all
        prescription_ids = UrgencyPrescription.where(urgency_encounter_id: encounter_ids).pluck(:id)
        UrgencyPrescriptionItem.where(urgency_prescription_id: prescription_ids).delete_all
        UrgencyPrescription.where(id: prescription_ids).delete_all
        UrgencyEncounter.where(id: encounter_ids).delete_all
        UrgencyClassification.where(urgency_encounter_id: encounter_ids).delete_all
        Consultation.where(attendance_id: attendance_ids).delete_all
        AttendanceCall.where(attendance_id: attendance_ids).delete_all
        Attendance.where(id: attendance_ids).delete_all
        Patient.where(id: patient_ids).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit, :doctor).merge(doc_user: ids[:nurse]))
    purge_committed_rows(doctor: ids[:second_doctor])
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def item
    { "catalog_item_id" => drug.id, "dose" => "50", "dose_unit" => "mg", "route" => "oral",
      "frequency" => { "kind" => "interval", "interval_hours" => 8 } }
  end

  def issue(by_id, expected)
    in_city do
      described_class.call(encounter: UrgencyEncounter.find(ids[:encounters].first), items: [ item ], catalog: { drug.id => drug },
                           by: User.find(by_id), expected_active_id: expected)
    end
  end

  it "Q16: dois médicos alteram a mesma v1 ao mesmo tempo: um emite a v2, o outro 409 prescription_changed" do
    v1 = issue(ids[:doctor], nil)
    expect(v1).to be_ok
    v1_id = v1.payload.fetch(:prescription).id

    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "urgency.prescription_issued"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << issue(ids[:doctor], v1_id) })
    holding.pop(timeout: 5) or raise "a primeira alteração não chegou a gravar a v2"

    second_result = Queue.new
    threads << other = Thread.new { second_result << issue(ids[:second_doctor], v1_id) }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera a trava do encontro

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results.map { |r| r.ok? ? :ok : r.reason }).to eq([ :ok, :prescription_changed ])
    in_city do
      versions = UrgencyPrescription.where(urgency_encounter_id: ids[:encounters].first).order(:version)
      expect(versions.pluck(:version, :status)).to eq([ [ 1, "superseded" ], [ 2, "active" ] ])
    end
  end
end
