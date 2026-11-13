require "rails_helper"

# Módulo 24b (ADR 0052; contrato §5, §13; Q8, Q15, Q21, Q32, Q41): a pessoa da
# visita, do participante e do item `patient` do envio — `patient_id` existente
# ou `new_patient` pelo Patients::CreateReviewed (savepoint próprio, na
# transação de quem grava). Recusas com os códigos reais do 24a e o `path` do
# campo (relativo ao item pelo `path_prefix`); duplicado com até 10 candidatos
# (sex, has_cns) e trilha por candidato.
RSpec.describe HomeVisits::People, type: :model do
  before { home_visit_city! }

  let(:by) { field_agent! }

  def typed(**over)
    { "full_name" => "Marta Gomes Pereira", "birth_date" => "1980-03-04", "sex" => "female", "mother_name" => "Ana Gomes Pereira",
      "cpf" => valid_cpf(registry_seq!) }.merge(over.stringify_keys)
  end

  def resolve(**args) = described_class.resolve(by: by, **args)
  def trail = DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at).map(&:payload)

  it "paciente novo com CPF cria (created: true, patient.created)" do
    result = nil
    expect { result = resolve(new_patient: typed) }.to change(Patient, :count).by(1)
    expect(result).to be_ok
    expect(result.payload[:created]).to be(true)
    patient = result.payload[:patient]
    expect(patient.reload).to have_attributes(full_name: "Marta Gomes Pereira", sex: "female", birth_date: "1980-03-04")
    expect(patient.cpf).to be_present
    expect(DomainEvent.where(name: "patient.created").pluck(:payload)).to include(include("patient_id" => patient.id, "user_id" => by.id))
  end

  it "patient_id existente → o paciente, created: false; provisório da UPA → patient_unidentified com o path do item (Q41)" do
    existing = registry_patient!
    result = resolve(patient_id: existing.id)
    expect(result.payload).to eq(patient: existing, created: false)

    provisional = Patient.create!(no_cpf_reason: "unidentified", unidentified: true, unidentified_description: "homem idoso")
    refused = resolve(patient_id: provisional.id)
    expect([ refused.reason, refused.details ]).to eq([ :patient_unidentified, { path: "patient_id" } ])
    refused = resolve(patient_id: provisional.id, path_prefix: "participants[2]")
    expect([ refused.reason, refused.details ]).to eq([ :patient_unidentified, { path: "participants[2].patient_id" } ])
  end

  it "nome+nascimento de alguém existente sem duplicates_reviewed → duplicate_suspected com até 10 candidatos; trilha só no candidates_viewed!" do
    twins = Array.new(11) do
      registry_no_cpf_patient!(cns: valid_cns(registry_seq!)).tap { |patient| patient.update!(full_name: "Marta Gomes Pereira", birth_date: "1980-03-04") }
    end
    result = nil
    expect { result = resolve(new_patient: typed, path_prefix: "participants[1]") }.not_to change(Patient, :count)
    expect(result.reason).to eq(:duplicate_suspected)
    expect(result.details[:path]).to eq("participants[1].new_patient")
    candidates = result.details[:candidates]
    expect(candidates.size).to eq(10)
    expect(candidates.first).to eq(patient_id: twins.first.id, display_name: "Marta Gomes Pereira", birth_date: "1980-03-04",
                                   sex: "female", has_cpf: false, has_cns: true)
    expect(result.details[:candidate_ids]).to eq(twins.first(10).map(&:id))
    expect(trail).to be_empty

    described_class.candidates_viewed!(candidate_ids: result.details[:candidate_ids], by: by, trail: HomeVisits::Trail)
    expect(trail.map { |payload| payload["patient_id"] }).to eq(twins.first(10).map(&:id))
    expect(trail).to all(include("access" => "home_visits", "user_id" => by.id))

    described_class.candidates_viewed!(candidate_ids: [ twins.first.id ], by: by, trail: CollectiveActivities::Trail)
    expect(trail.last).to include("access" => "collective_activities", "patient_id" => twins.first.id)
  end

  it "transação de fora desfeita depois do duplicate_suspected: a trilha dos candidatos, gravada depois, fica" do
    twin = registry_no_cpf_patient!(cns: valid_cns(registry_seq!)).tap { |patient| patient.update!(full_name: "Marta Gomes Pereira", birth_date: "1980-03-04") }
    result = nil
    ApplicationRecord.transaction(requires_new: true) do
      first = resolve(new_patient: typed(full_name: "Clara Nunes Dias"), path_prefix: "participants[0]")
      expect(first).to be_ok
      result = resolve(new_patient: typed, path_prefix: "participants[1]")
      raise ActiveRecord::Rollback
    end
    expect(result.reason).to eq(:duplicate_suspected)
    expect(Patient.count).to eq(1)
    described_class.candidates_viewed!(candidate_ids: result.details[:candidate_ids], by: by, trail: CollectiveActivities::Trail)
    expect(trail).to eq([ { "access" => "collective_activities", "patient_id" => twin.id, "user_id" => by.id, "reason_code" => nil,
                            "person_ref" => "patient:#{twin.id}" } ])
  end

  it "com duplicates_reviewed true cria; nil vale false; reviewed não booleano → invalid_request com o path" do
    registry_no_cpf_patient!(cns: valid_cns(registry_seq!)).update!(full_name: "Marta Gomes Pereira", birth_date: "1980-03-04")
    expect(resolve(new_patient: typed, reviewed: nil).reason).to eq(:duplicate_suspected)
    result = resolve(new_patient: typed, reviewed: true)
    expect(result).to be_ok
    expect(result.payload[:created]).to be(true)

    refused = resolve(new_patient: typed, reviewed: "yes", path_prefix: "participants[0]")
    expect([ refused.reason, refused.details ]).to eq([ :invalid_request, { path: "participants[0].duplicates_reviewed" } ])
  end

  it "CPF de outro → cpf_taken com path new_patient.cpf; CNS de outro → cns_taken" do
    other = registry_patient!
    refused = resolve(new_patient: typed(cpf: other.cpf))
    expect([ refused.reason, refused.details ]).to eq([ :cpf_taken, { path: "new_patient.cpf" } ])

    with_cns = registry_no_cpf_patient!(cns: valid_cns(registry_seq!))
    refused = resolve(new_patient: typed(cns: with_cns.cns), path_prefix: "participants[3]")
    expect([ refused.reason, refused.details ]).to eq([ :cns_taken, { path: "participants[3].new_patient.cns" } ])
  end

  it "os códigos reais do 24a, sempre com path; forma do pedido → invalid_request" do
    cases = {
      typed(full_name: "X") => [ :invalid_patient, "new_patient.full_name" ],
      typed(sex: "other") => [ :invalid_patient, "new_patient.sex" ],
      typed(cpf: nil) => [ :cpf_or_reason_required, "new_patient.no_cpf_reason" ],
      typed(cpf: "123") => [ :invalid_cpf, "new_patient.cpf" ],
      typed(cpf: nil, no_cpf_reason: "3", cns: "123") => [ :invalid_cns, "new_patient.cns" ],
      typed(nickname: "Ma") => [ :invalid_request, "new_patient.nickname" ],
      typed(social_name: "Ma") => [ :invalid_request, "new_patient.social_name" ]
    }
    cases.each do |new_patient, (reason, path)|
      refused = resolve(new_patient: new_patient)
      expect([ new_patient.keys, refused.reason, refused.details ]).to eq([ new_patient.keys, reason, { path: path } ])
    end
    expect(resolve(new_patient: "Marta").then { |r| [ r.reason, r.details ] }).to eq([ :invalid_request, { path: "new_patient" } ])
    expect(resolve.then { |r| [ r.reason, r.details ] }).to eq([ :invalid_request, { path: "patient_id" } ])
    expect(resolve(patient_id: registry_patient!.id, new_patient: typed).then { |r| [ r.reason, r.details ] })
      .to eq([ :invalid_request, { path: "new_patient" } ])
    expect(resolve(patient_id: "nope").then { |r| [ r.reason, r.details ] }).to eq([ :invalid_request, { path: "patient_id" } ])
    expect(resolve(patient_id: SecureRandom.uuid).then { |r| [ r.reason, r.details ] }).to eq([ :not_found, { path: "patient_id" } ])
    expect(Patient.count).to eq(1)
  end

  it "recusa desfaz só o savepoint: a transação de quem grava segue e o que ela gravou antes fica" do
    other = registry_patient!
    ApplicationRecord.transaction do
      kept = registry_patient!
      refused = resolve(new_patient: typed(cpf: other.cpf))
      expect(refused.reason).to eq(:cpf_taken)
      created = resolve(new_patient: typed(full_name: "Clara Nunes Dias"))
      expect(created).to be_ok
      expect(Patient.where(id: [ kept.id, created.payload[:patient].id ]).count).to eq(2)
    end
    expect(Patient.where(cpf: other.cpf).count).to eq(1)
    expect(Patient.count).to eq(3)
  end

  it "o candidato do item do 24a no app leva registration_id (uuid ou nulo; Q26)" do
    patient = registry_patient!
    expect(described_class.candidate(patient, registration: true)).to include(registration_id: nil, has_cns: false)
    expect(described_class.candidate(patient)).not_to have_key(:registration_id)
  end
end
