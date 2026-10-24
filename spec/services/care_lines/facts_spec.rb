require "rails_helper"

RSpec.describe CareLines::Facts do
  include ActiveSupport::Testing::TimeHelpers

  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }

  it "monta a pessoa do paciente com problemas ativos e resolvidos, em pares, e sem dado pessoal no inspect" do
    patient = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    person = described_class.patients([ patient.id ]).fetch(patient.id)
    expect(person.patient_id).to eq(patient.id)
    expect(person.sex).to eq("male")
    expect(person.birth_date).to be_a(Date)
    expect(person.problems).to eq([ %w[ciap2 T90] ])
    expect(person.resolved_problems).to eq([])
    expect([ person.inspect, person.to_s, person.as_json.to_json ].join).not_to include("male", "T90", person.birth_date.to_s)
    expect(person.problem_since).to eq({ %w[ciap2 T90] => Time.zone.today })
    shown = [ person.inspect, person.to_s, PP.pp(person, +""), person.to_json, person.as_json.to_s ].join
    expect(shown).not_to include("problem_since", "T90", Time.zone.today.iso8601)
  end

  describe "problem_since: dia em que o problema passou a estar ativo pela última vez" do
    def active_problem_event!(patient, kind:)
      PatientProblem.find_by!(patient_id: patient.id, status: "active").then do |problem|
        PatientProblemEvent.where(patient_problem_id: problem.id, kind: kind).maximum(:created_at)
      end
    end

    it "é o dia do evento added, no fuso da cidade" do
      travel_to(Time.zone.local(2026, 3, 10, 22, 30)) do
        patient = care_patient!(age: 30, sex: "female", problems: [ %w[ciap2 W82] ], unit: unit, doctor: doctor)
        since = described_class.patients([ patient.id ]).fetch(patient.id).problem_since
        expect(since).to eq({ %w[ciap2 W82] => Time.zone.today })
        expect(since.values.first).to eq(active_problem_event!(patient, kind: "added").in_time_zone.to_date)
      end
    end

    it "problema reativado conta a reativação, não o primeiro registro" do
      patient = nil
      travel_to(Time.zone.local(2026, 1, 5, 10)) do
        patient = care_patient!(age: 30, sex: "female", problems: [ %w[ciap2 W82] ], unit: unit, doctor: doctor)
        resolve_problem!(patient, "W82", by: doctor)
      end
      travel_to(Time.zone.local(2026, 6, 20, 10)) do
        consultation = patient.consultations.finalized_consultations.order(:finalized_at).last
        release = PatientProblem.find_by!(patient_id: patient.id).terminology_release_id
        ApplicationRecord.transaction do
          patient.lock!
          result = Patients::ApplyProblemEvent.call(patient: patient, action: "add", by: doctor, source: { consultation: consultation },
                                                    terminology: "ciap2", code: "W82", release_id: release)
          expect(result).to be_ok
          expect(result.payload[:event].kind).to eq("reactivated")
        end
        person = described_class.patients([ patient.id ]).fetch(patient.id)
        expect(person.problem_since).to eq({ %w[ciap2 W82] => Date.new(2026, 6, 20) })
      end
    end

    it "problema resolvido não entra, e quem não tem problema recebe hash vazio" do
      healthy = care_patient!(age: 30, sex: "female")
      expect(described_class.patients([ healthy.id ]).fetch(healthy.id).problem_since).to eq({})
    end
  end

  it "separa problema resolvido do ativo" do
    patient = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    ApplicationRecord.transaction do
      Patients::ApplyProblemEvent.call(patient: patient, action: "resolve", problem: PatientProblem.find_by!(patient_id: patient.id), by: doctor,
                                       source: { consultation: Struct.new(:id).new(SecureRandom.uuid) })
    end
    person = described_class.patients([ patient.id ]).fetch(patient.id)
    expect(person.problems).to eq([])
    expect(person.resolved_problems).to eq([ %w[ciap2 T90] ])
  end

  it "traz identidade de gênero e condições declaradas do par ligado ao paciente" do
    patient = care_patient!(age: 30, sex: "female", gender_identity: "trans_man")
    citizen = Citizen.find_by!(patient_id: patient.id)
    CitizenDeclaredCondition.create!(citizen: citizen, condition: "diabetes", declared_at: Time.current)
    person = described_class.patients([ patient.id ]).fetch(patient.id)
    expect(person.gender_identity).to eq("trans_man")
    expect(person.declared).to eq(%w[diabetes])
  end

  it "citizens: só par validado sem paciente e não apagado" do
    free = care_citizen!(age: 72, sex: "female", gender_identity: "cis_woman")
    linked = care_patient!(age: 40, sex: "female")
    people = described_class.citizens([ free.id, Citizen.find_by!(patient_id: linked.id).id ])
    expect(people.keys).to eq([ free.id ])
    expect(people[free.id].citizen_id).to eq(free.id)
  end

  # Revisão final do 24a (M2): um par por CPF no SQL. "Já tem paciente" é um
  # NOT EXISTS correlacionado (anti-join pelo índice de patients.cpf) — NOT IN
  # (subconsulta) não vira anti-join no Postgres e varreria os CPFs da cidade.
  it "one_per_cpf: sem paciente do CPF e o par mais antigo do CPF, por anti-join no índice de patients.cpf" do
    oldest = care_citizen!(age: 30, sex: "female")
    twin = travel_to(1.minute.from_now) { Citizen.create!(cpf: oldest.cpf, phone: "+5541990000001", verification_level: "verified") }
    taken = care_citizen!(age: 31, sex: "male")
    Patient.create!(cpf: taken.cpf, full_name: "Paciente Digitado", birth_date: "1990-01-01", sex: "male")
    scope = Citizen.where(id: [ oldest.id, twin.id, taken.id ])
    expect(described_class.one_per_cpf(scope).pluck(:id)).to eq([ oldest.id ])

    sql = described_class.one_per_cpf(Citizen.where(patient_id: nil)).to_sql
    expect(sql).not_to match(/NOT IN/i)
    plan = ApplicationRecord.transaction(requires_new: true) do
      ApplicationRecord.connection.execute("SET LOCAL enable_seqscan = off")
      ApplicationRecord.connection.select_values("EXPLAIN #{sql}").join("\n")
    end
    expect(plan).to include("Anti Join", "index_patients_on_cpf")
    expect(plan).not_to include("SubPlan")
  end

  it "problem_candidates acha por prefixo do código ativo, na terminologia certa" do
    hit = care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    care_patient!(age: 60, sex: "male", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor)
    expect(described_class.problem_candidates({ "ciap2" => %w[T90], "cid10" => %w[E11] })).to eq([ hit.id ])
    expect(described_class.problem_candidates({ "cid10" => %w[T90] })).to eq([])
    expect(described_class.problem_candidates({})).to eq([])
  end

  it "ids vazios não consultam" do
    expect(described_class.patients([])).to eq({})
    expect(described_class.citizens([])).to eq({})
  end

  # Módulo 24a (contrato §9; F-24.8): a saída do cadastro individual por óbito
  # também é a marca do óbito, junto da inscrição encerrada por death.
  it "deceased: saída do cadastro por óbito também marca, junto da inscrição encerrada por óbito, numa consulta" do
    registry_city!
    exit = lambda do |registration, reason|
      params = { "reason" => reason, "on" => Time.zone.today.iso8601 }
      params["death_on"] = Time.zone.today.iso8601 if reason == "death"
      expect(TerritoryRegistry::ExitRegistration.call(registration: registration, params: params,
                                                       by: registry_acs_of(registration.household))).to be_ok
    end
    dead = registry_registration!
    exit.call(dead, "death")
    moved = registry_registration!
    exit.call(moved, "moved")
    alive = registry_registration!
    enrolled = care_patient!(age: 60, sex: "male")
    care_enrollment!(patient: enrolled, line: adopted_line!("diabetes_c4"), team: care_team!(unit, doctor), by: doctor)
      .update!(status: "ended", ended_reason: "death", ended_at: 1.day.ago, ended_by_user: doctor)
    ids = [ dead.patient_id, moved.patient_id, alive.patient_id, enrolled.id ]
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
    result = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { described_class.deceased(ids) }
    expect(result).to eq(Set[dead.patient_id, enrolled.id])
    expect(count).to eq(1)
  end
end
