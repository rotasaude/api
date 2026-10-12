require "rails_helper"

# Spec §4 (ADR 0035): problemas ativos (nome), medicamentos em uso, exames
# solicitados nos últimos 12 meses e a última PA, peso e glicemia com data.
# Nunca CID sem nome; nunca texto da consulta.
RSpec.describe Timeline::CitizenSummary do
  include ActiveSupport::Testing::TimeHelpers
  before { timeline_city!(documents: true); ciap2_release!; cid10_release!; sigtap_release!; acolhimento! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:nurse) { screener!(unit) }
  let(:citizen) { verified_citizen!(121) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen) }
  let(:patient) { consultation.patient }
  let(:person) { Timeline::Person.for_patient(patient) }

  it "monta as quatro partes a partir da consulta, da lista de medicamentos e da escuta" do
    ApplicationRecord.transaction do
      Patients::ApplyMedicationEvent.call(patient: patient, action: "add", by: doctor, source: { consultation: consultation },
                                          origin: "external", free_text: "Losartana 50 mg", dosage_summary: "1 comprimido pela manhã")
    end
    travel_to(1.hour.from_now) do
      attendance = walk_in_attendance!(unit, citizen: citizen)
      started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
      Screenings::Complete.call(screening: started,
                                revision_params: revision_params(vitals: { "systolic" => 128, "diastolic" => 82,
                                                                           "capillary_glucose" => 110, "glucose_moment" => "fasting" }),
                                destination: "oriented", destination_params: { "orientation_note" => "retorno se piorar" }, by: nurse)
    end
    summary = described_class.call(patient: patient, person: person, now: 2.hours.from_now)
    expect(summary[:problems]).to eq([ { terminology: "ciap2", code: "T90", label: "Diabetes não insulino-dependente",
                                         since: "2025-08-01" } ])
    expect(summary[:medications]).to eq([ { label: "Losartana 50 mg", dosage_summary: "1 comprimido pela manhã", since: Time.zone.today.iso8601 } ])
    expect(summary[:exam_requests].map { |e| e.slice(:sigtap_code, :label) })
      .to eq([ { sigtap_code: "0202010503", label: "DOSAGEM DE HEMOGLOBINA GLICOSILADA" } ])
    expect(summary[:vitals][:blood_pressure]).to include(systolic: 128, diastolic: 82)
    expect(summary[:vitals][:weight_kg]).to eq(value: 82.5, measured_at: consultation.finalized_at.iso8601)
    expect(summary[:vitals][:capillary_glucose]).to include(value: 110, moment: "fasting")
    expect(summary.to_s).not_to include("Refere sede", "retorno se piorar")
  end

  it "problema sem nome não aparece; exame de mais de 12 meses não aparece" do
    allow(ClinicalTerms).to receive(:label).and_return(nil)
    expect(described_class.call(patient: patient, person: person)[:problems]).to eq([])
    expect(described_class.call(patient: patient, person: person, now: 13.months.from_now)[:exam_requests]).to eq([])
  end
end
