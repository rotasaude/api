# spec/commands/patients/apply_medication_event_spec.rb
require "rails_helper"

# ADR 0033 (spec §5; Invariantes): a lista de medicamentos em uso é estado
# atual reconstruído de eventos (só acréscimos), como a de problemas; um
# ativo por paciente + item; cada evento ligado a UMA consulta, adendo ou
# documento.
RSpec.describe Patients::ApplyMedicationEvent do
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release!; import_test_catalog! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:patient) { consultation.patient }
  let(:losartana) { catalog_item(268_856) }

  def apply(source: { consultation: consultation }, **args)
    ApplicationRecord.transaction do
      Patient.lock.find(patient.id)
      described_class.call(patient: patient, by: doctor, source: source, **args)
    end
  end

  it "inclui, muda a posologia, suspende e reativa — cada passo um evento" do
    added = apply(action: "add", catalog_item: losartana, dosage_summary: "1 cp de manhã")
    medication = added.payload[:medication]
    expect(medication).to have_attributes(status: "active", origin: "prescription", label: "LOSARTANA POTÁSSICA 50 MG",
                                          catmat_code: 268_856, continuous: true, started_on: Time.zone.today)
    expect(apply(action: "add", catalog_item: losartana, dosage_summary: "1 cp de manhã").payload[:event]).to be_nil
    expect(apply(action: "add", catalog_item: losartana, dosage_summary: "1 cp 12/12h").payload[:event].kind).to eq("changed")
    expect(apply(action: "suspend", medication: medication.reload).payload[:medication].status).to eq("suspended")
    reactivated = apply(action: "add", catalog_item: losartana, dosage_summary: "1 cp de manhã")
    expect([ reactivated.payload[:event].kind, reactivated.payload[:medication].id ]).to eq([ "reactivated", medication.id ])
    expect(medication.events.order(:created_at).pluck(:kind)).to eq(%w[added changed suspended reactivated])
    expect(PatientMedication.where(patient: patient).count).to eq(1)
    payloads = DomainEvent.where(name: "patient_medication.changed").order(:occurred_at, :created_at).pluck(:payload)
    expect(payloads.last).to eq("patient_medication_id" => medication.id, "kind" => "reactivated", "consultation_id" => consultation.id)
    expect(payloads.to_json).not_to include("LOSARTANA", "12/12h")
  end

  it "informado de fora com o mesmo item ativo → already_active; reativar ativo → already_active" do
    medication = apply(action: "add", catalog_item: losartana, dosage_summary: "1 cp").payload[:medication]
    expect(apply(action: "add", origin: "external", catalog_item: losartana, on_active: :fail).reason).to eq(:already_active)
    expect(apply(action: "reactivate", medication: medication).reason).to eq(:already_active)
  end

  it "texto livre: casa sem acento, caixa ou espaço extra" do
    first = apply(action: "add", origin: "external", free_text: "Chá de camomila", dosage_summary: "à noite", on_active: :fail)
    expect(first.payload[:medication]).to have_attributes(free_text: "Chá de camomila", catalog_item_id: nil, origin: "external")
    expect(apply(action: "add", origin: "external", free_text: "  CHA  de Camomila ", on_active: :fail).reason).to eq(:already_active)
  end

  it "medicamento de outro paciente, ação desconhecida ou suspender o que não está ativo → invalid_medication" do
    medication = apply(action: "add", catalog_item: losartana).payload[:medication]
    other = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2, full_name: "João Souza")).patient
    expect(ApplicationRecord.transaction { described_class.call(patient: other, action: "suspend", by: doctor, source: { consultation: consultation }, medication: medication) }.reason)
      .to eq(:invalid_medication)
    expect(apply(action: "apagar", medication: medication).reason).to eq(:invalid_medication)
    apply(action: "suspend", medication: medication)
    expect(apply(action: "suspend", medication: medication.reload).reason).to eq(:invalid_medication)
  end

  it "fonte: exatamente uma entre consulta, adendo e documento" do
    consultation # criada fora da transação que o ArgumentError desfaz
    expect { apply(action: "add", catalog_item: losartana, source: {}) }.to raise_error(ArgumentError)
    expect do
      described_class.call(patient: patient, action: "add", by: doctor, catalog_item: losartana,
                           source: { consultation: consultation, document: raw_document!(consultation: consultation) })
    end.to raise_error(ArgumentError)
  end
end
