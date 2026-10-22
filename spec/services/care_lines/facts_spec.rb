require "rails_helper"

RSpec.describe CareLines::Facts do
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
end
