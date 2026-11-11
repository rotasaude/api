require "rails_helper"

# Review Focus 1 do plano do 32b (ADR 0050; contrato §4): dois profissionais,
# dois pacientes, o mesmo leito ao mesmo tempo. A primeira entrada fica parada
# depois de inserir a estadia (antes do commit); a segunda passa pela
# conferência do Ruby (não vê a estadia ainda não commitada), esbarra na
# exclusion `excl_urgency_bed_stays_bed` e espera; solta a primeira, a segunda
# recebe bed_taken e o leito fica com um ocupante só. Threads reais contra
# TEST_CITY_A (sem fixture transacional), como
# spec/commands/urgency/identify_concurrency_spec.rb; o after solta as
# threads e apaga tudo o que commitou.
RSpec.describe Urgency::StartObservation, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  def professional!(tag, suffix, cbo, admin)
    user = User.create!(email_address: "#{suffix}-#{tag}@c.gov.br", password: "senha-segura-123")
    yield user.id
    Membership.create!(user: user, role: "health_professional", granted_at: Time.current)
    professional = Professional.create!(user: user, professional_name: "Profissional #{suffix}", council: "CRM", council_state: "PR",
                                        registration_number: "#{tag.to_i(16).to_s[0, 6]}#{suffix.length}",
                                        cns: Professionals::Cns.generate("obs:#{tag}:#{suffix}"))
    ProfessionalLink.create!(professional: professional, health_unit_id: ids[:unit], cbo_code: cbo, started_at: Time.current,
                             started_by_user: admin)
    user
  end

  before do
    in_city do
      tag = SecureRandom.hex(4)
      # Cada id entra em `ids` assim que a linha nasce: se o before falhar no
      # meio, o after ainda limpa o que já foi commitado.
      reception = User.create!(email_address: "recepcao-obs-#{tag}@c.gov.br", password: "senha-segura-123")
      ids[:admin] = reception.id
      Membership.create!(user: reception, role: "citizen_verifier", granted_at: Time.current)
      ids[:unit] = HealthUnit.create!(name: "UPA Leito #{tag}", kind: "upa").id
      doctor = professional!(tag, "medico", "225125", reception) { |id| ids[:doctor] = id }
      nurse = professional!(tag, "enfermeira", "223505", reception) { |id| ids[:doc_user] = id }
      ids[:bed] = UrgencyBed.create!(health_unit_id: ids[:unit], label: "OBS 01", updated_by_user: reception).id
      ids[:patients] = []
      ids[:encounters] = []
      ids[:attendances] = []
      2.times do |n|
        attrs = { "full_name" => "Carlos Eduardo Pinto", "birth_date" => "1980-01-0#{n + 1}", "sex" => "male",
                  "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("obs-paciente:#{tag}:#{n}") }
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
        UrgencyBedStay.where(urgency_encounter_id: encounter_ids).delete_all
        UrgencyBed.where(id: ids.values_at(:bed, :bed2).compact).delete_all
        # Sob `replica` as FKs não disparam: o encontro sai antes das classificações.
        UrgencyEncounter.where(id: encounter_ids).delete_all
        UrgencyClassification.where(urgency_encounter_id: encounter_ids).delete_all
        AttendanceCall.where(attendance_id: attendance_ids).delete_all
        Attendance.where(id: attendance_ids).delete_all
        Patient.where(id: patient_ids).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit, :doctor, :doc_user))
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def enter(encounter_id, by_id)
    in_city do
      described_class.call(encounter: UrgencyEncounter.find(encounter_id), bed_id: ids[:bed], by: User.find(by_id))
    end
  end

  it "dois profissionais, dois pacientes, o mesmo leito ao mesmo tempo: um vence, o outro 409 bed_taken" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "urgency.observation_started"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    first, second = ids[:encounters]

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << enter(first, ids[:doctor]) })
    holding.pop(timeout: 5) or raise "a primeira entrada não chegou a gravar a estadia"

    second_result = Queue.new
    threads << other = Thread.new { second_result << enter(second, ids[:doc_user]) }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera na exclusion do leito

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results.map { |r| r.ok? ? :ok : r.reason }).to eq([ :ok, :bed_taken ])
    in_city do
      expect(UrgencyBedStay.open_stays.where(urgency_bed_id: ids[:bed]).pluck(:urgency_encounter_id)).to eq([ first ])
      expect(UrgencyBedStay.where(urgency_encounter_id: second)).to be_empty
      expect(DomainEvent.where(name: "urgency.observation_started").where("payload->>'encounter_id' IN (?)", ids[:encounters]).count).to eq(1)
    end
  end

  # Q15: duas telas sobre o MESMO paciente, as duas sem estadia aberta no mapa.
  # A primeira entrada fica parada antes do commit; a segunda (expected_stay_id
  # null, leito diferente) espera a trava do encontro; solta a primeira, a
  # segunda vê a estadia nova e recebe observation_changed, sem trocar o leito.
  it "Q15: duas entradas do mesmo paciente com a tela velha: uma vence, a outra 409 observation_changed" do
    in_city do
      ids[:bed2] = UrgencyBed.create!(health_unit_id: ids[:unit], label: "OBS 02", updated_by_user: User.find(ids[:admin])).id
    end
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "urgency.observation_started"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    encounter = ids[:encounters].first
    run = lambda do |bed_id, by_id|
      in_city do
        described_class.call(encounter: UrgencyEncounter.find(encounter), bed_id: bed_id, by: User.find(by_id),
                             expected_stay_id: nil)
      end
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << run.call(ids[:bed], ids[:doctor]) })
    holding.pop(timeout: 5) or raise "a primeira entrada não chegou a gravar a estadia"

    second_result = Queue.new
    threads << other = Thread.new { second_result << run.call(ids[:bed2], ids[:doc_user]) }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera a trava do encontro

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    results = [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ]
    expect(results.map { |r| r.ok? ? :ok : r.reason }).to eq([ :ok, :observation_changed ])
    in_city do
      expect(UrgencyBedStay.where(urgency_encounter_id: encounter).pluck(:urgency_bed_id, :ended_at)).to eq([ [ ids[:bed], nil ] ])
    end
  end
end
