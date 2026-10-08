# spec/services/clinical_record/json_spec.rb
require "rails_helper"

# Contratos §3: <record> com o paciente (nome de exibição; idade e sexo),
# problemas, escuta do dia e consultas; trilha só com ids, acesso e motivo.
RSpec.describe ClinicalRecord::Json do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:grant) { ClinicalRecord::Access::Grant.new(kind: :in_context, opening: nil, reason: nil) }

  it "paciente com consulta: bloco do paciente, problemas, consultas" do
    citizen = verified_citizen!(1, social_name: "Mariana", age: 46)
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    json = described_class.record(patient: consultation.patient, citizen: citizen, grant: grant).deep_stringify_keys
    expect(json.keys).to match_array(%w[patient access problems today_screening consultations])
    expect(json["patient"]).to eq("id" => consultation.patient_id, "display_name" => "Mariana",
                                  "full_name" => "Maria Aparecida da Silva", "social_name" => "Mariana",
                                  "age" => 46, "sex" => "female", "cpf_masked" => citizen.cpf_masked)
    expect(json["access"]).to eq("in_context")
    expect(json["problems"].sole).to eq("id" => PatientProblem.sole.id, "terminology" => "ciap2", "code" => "T90",
                                        "label" => "Diabetes não insulino-dependente", "status" => "active",
                                        "onset_on" => "2025-08-01", "onset_precision" => "month", "resolved_on" => nil)
    # Opcionais só com valor (§9): sem início, onset_* saem da chave; resolved_on fica.
    bare = described_class.problem(PatientProblem.sole.dup.tap { |p| p.assign_attributes(onset_on: nil, onset_precision: nil) }).keys
    expect(bare).not_to include(:onset_on, :onset_precision)
    expect(bare).to include(:resolved_on)
    expect(json["consultations"].sole["id"]).to eq(consultation.id)
    expect(json["today_screening"]).to be_nil
  end

  it "par validado sem paciente ainda: id nulo, listas vazias" do
    citizen = verified_citizen!(2)
    json = described_class.record(patient: nil, citizen: citizen, grant: grant).deep_stringify_keys
    expect(json["patient"]).to include("id" => nil, "display_name" => "Maria Aparecida da Silva")
    expect(json.values_at("problems", "consultations")).to eq([ [], [] ])
  end

  it "trilha: só ids, acesso e motivo; nada sem paciente" do
    patient = Patients::Resolve.call(verified_citizen!(3)).payload[:patient]
    nurse = doctor!(unit, cbo: "223505")
    now = Time.current
    opening = ClinicalRecordOpening.create!(patient: patient, user: nurse, reason_code: "other", reason_note: "nota MARCADOR",
                                            created_at: now, expires_at: now + 30.minutes)
    ClinicalRecord::Trail.viewed!(patient: patient, user: nurse,
                                  grant: ClinicalRecord::Access::Grant.new(kind: :justified, opening: opening, reason: nil))
    ClinicalRecord::Trail.viewed!(patient: nil, user: nurse, grant: grant)
    expect(DomainEvent.where(name: "clinical_record.viewed").pluck(:payload))
      .to eq([ { "patient_id" => patient.id, "user_id" => nurse.id, "access" => "justified", "reason_code" => "other" } ])
  end
end
