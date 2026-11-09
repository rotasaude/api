require "rails_helper"

# Review Focus 1 do plano do 32a (ADR 0050, R4): duas recepcionistas
# identificam o mesmo provisório ao mesmo tempo, cada uma com um paciente real
# diferente. A trava do provisório (FOR UPDATE) segura a segunda até a
# primeira commitar; relido sob a trava, o provisório já está fundido e a
# segunda recebe already_identified. Nenhuma linha fica dividida entre os dois
# reais e o merged_into_id não muda. Threads reais contra TEST_CITY_A (sem
# fixture transacional), como spec/commands/attendances/call_next_concurrency_spec.rb;
# o after solta as threads e apaga tudo o que commitou.
RSpec.describe Urgency::Identify, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        # Cada id entra em `ids` assim que a linha nasce: se o before falhar no
        # meio, o after ainda limpa o que já foi commitado.
        reception = User.create!(email_address: "recepcao-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:admin] = reception.id
        Membership.create!(user: reception, role: "citizen_verifier", granted_at: Time.current)
        ids[:unit] = HealthUnit.create!(name: "UPA Disputa #{tag}", kind: "upa").id
        ids[:patients] = []
        ids[:reals] = [ 1, 2 ].map do |n|
          attrs = { "full_name" => "Carlos Eduardo Pinto", "birth_date" => "1980-01-0#{n}", "sex" => "male",
                    "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("disputa:#{tag}:#{n}") }
          patient = Patients::CreateTyped.call(attrs: attrs, by: reception).payload.fetch(:patient)
          ids[:patients] << patient.id
          patient.id
        end
        arrived = Urgency::Arrive.call(health_unit_id: ids[:unit], unidentified: { "description" => "Homem, 50 anos, na praça" },
                                       by: reception, waiting_room: false)
        encounter = arrived.payload.fetch(:encounter)
        ids[:encounter] = encounter.id
        ids[:attendance] = encounter.attendance_id
        ids[:provisional] = encounter.attendance.patient_id
        ids[:patients] << ids[:provisional]
        # Além do atendimento, uma consulta e um problema do provisório: a
        # fusão não pode dividir nenhuma das tabelas entre os dois reais.
        doctor = User.create!(email_address: "doc-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:doctor] = doctor.id
        Membership.create!(user: doctor, role: "health_professional", granted_at: Time.current)
        professional = Professional.create!(user: doctor, professional_name: "Médica da UPA", council: "CRM", council_state: "PR",
                                            registration_number: tag.to_i(16).to_s[0, 7], cns: Professionals::Cns.generate("disputa-doc:#{tag}"))
        link = ProfessionalLink.create!(professional: professional, health_unit_id: ids[:unit], cbo_code: "225125",
                                        started_at: Time.current, started_by_user: reception)
        ids[:consultation] = Consultation.create!(attendance_id: ids[:attendance], patient_id: ids[:provisional], author_user: doctor,
                                                  professional_link: link, cbo_code: link.cbo_code, status: "draft",
                                                  started_at: Time.current).id
        ids[:problem] = SecureRandom.uuid
        ApplicationRecord.transaction do
          PatientProblemEvent.create!(patient_problem_id: ids[:problem], kind: "added", consultation_id: ids[:consultation], user: doctor,
                                      status_after: "active")
          PatientProblem.create!(id: ids[:problem], patient_id: ids[:provisional], terminology: "ciap2", code: "T90", status: "active",
                                 # A versão da terminologia mora na plataforma (sem FK na cidade):
                                 # criá-la aqui commitaria uma versão ativa imutável para os outros specs.
                                 terminology_release_id: SecureRandom.uuid)
        end
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
        DomainEvent.where("payload->>'patient_id' IN (?) OR payload->>'encounter_id' = ? OR payload->>'attendance_id' = ?",
                          patient_ids.presence || [ "" ], ids[:encounter].to_s, ids[:attendance].to_s).delete_all
        PatientProblemEvent.where(patient_problem_id: ids[:problem]).delete_all
        PatientProblem.where(id: ids[:problem]).delete_all
        UrgencyEncounter.where(id: ids[:encounter]).delete_all
        Consultation.where(id: ids[:consultation]).delete_all
        Attendance.where(id: ids[:attendance]).delete_all
        Patient.where(id: patient_ids).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit, :doctor))
  end

  def identify(target_id)
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        described_class.call(encounter: UrgencyEncounter.find(ids[:encounter]), patient_id: target_id, by: User.find(ids[:admin]))
      end
    end
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  it "duas identificações ao mesmo tempo: a primeira funde, a segunda espera a trava e recebe already_identified" do
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "urgency.patient_identified"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    first, second = ids[:reals]

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << identify(first) })
    holding.pop(timeout: 5) or raise "a primeira identificação não chegou ao fim da fusão"

    second_result = Queue.new
    threads << other = Thread.new { second_result << identify(second) }
    expect(wait_for_lock_wait).to be(true) # a segunda espera a trava do provisório

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    expect(first_result.pop(timeout: 1)).to be_ok
    expect(second_result.pop(timeout: 1).reason).to eq(:already_identified)
    in_city do
      expect(Patient.find(ids[:provisional]).merged_into_id).to eq(first)
      expect(Attendance.find(ids[:attendance]).patient_id).to eq(first)
      expect(Consultation.find(ids[:consultation]).patient_id).to eq(first)
      expect(PatientProblem.find(ids[:problem]).patient_id).to eq(first)
      expect(UrgencyEncounter.find(ids[:encounter]).provisional_patient_id).to eq(ids[:provisional])
      Urgency::Merge::TABLES.each do |table|
        count = ApplicationRecord.connection.select_value(
          "SELECT count(*) FROM #{table} WHERE patient_id IN (#{[ ids[:provisional], second ].map { ApplicationRecord.connection.quote(_1) }.join(', ')})"
        ).to_i
        expect(count).to eq(0), "#{table}: linha no provisório ou no segundo real"
      end
      expect(DomainEvent.where(name: "urgency.patient_identified").where("payload->>'encounter_id' = ?", ids[:encounter]).count).to eq(1)
    end
  end
end
