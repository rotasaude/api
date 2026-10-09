# spec/services/consultations/json_spec.rb
require "rails_helper"

# Contratos §4: a forma <consultation> no rascunho (itens de draft_items, com
# rótulo) e finalizada (itens gravados, adendos em ordem); opcionais só com valor.
RSpec.describe Consultations::Json do
  before { Current.city = clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:keys) do
    %w[id attendance_id patient_id status author cbo_code subjective objective assessment plan vitals care_type
       evaluated_problems conducts exam_requests started_at finalized_at addenda]
  end

  it "rascunho: chaves do contrato, itens do rascunho com rótulo, sinais com IMC" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: doctor)
    json = described_class.consultation(consultation.reload).deep_stringify_keys
    expect(json.keys).to match_array(keys)
    expect(json["author"]).to eq("id" => doctor.id, "name" => doctor.professional.professional_name)
    expect(json["vitals"]).to eq("systolic" => 130, "diastolic" => 85, "weight_kg" => 82.5, "height_cm" => 170, "bmi" => 28.5)
    expect(json["evaluated_problems"]).to eq([ { "problem_id" => nil, "terminology" => "ciap2", "code" => "T90",
                                                 "label" => "Diabetes não insulino-dependente", "action" => "add",
                                                 "onset_on" => "2025-08-01", "onset_precision" => "month" } ])
    expect(json["exam_requests"]).to eq([ { "sigtap_code" => "0202010503", "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA" } ])
    expect(json.values_at("status", "conducts", "finalized_at", "addenda")).to eq([ "draft", [ "1" ], nil, [] ])
    expect(json["care_type"]).to eq("5")
  end

  # Revisão final: `changes` na MESMA forma dos itens da consulta (rótulo,
  # opcionais só com valor, códigos de conduta como string), nunca o cru.
  it "adendo: changes passa pelos serializadores dos itens da consulta" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    Consultations::AddAddendum.call(
      consultation: consultation, by: doctor, reason: "correção estruturada", text: "ajuste",
      changes: { "evaluated_problems" => [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ],
                 "conducts" => [ "1", 9 ],
                 "exam_requests" => [ { "sigtap_code" => "0202010503" },
                                      { "sigtap_code" => "0202010317", "cid10_justification" => "E119" } ] }
    )
    changes = described_class.consultation(consultation.reload).deep_stringify_keys["addenda"].sole["changes"]
    expect(changes).to eq(
      "evaluated_problems" => [ { "problem_id" => nil, "terminology" => "cid10", "code" => "E119",
                                  "label" => ClinicalTerms.label("cid10", "E119", TerminologyRelease.active.find_by!(kind: "cid10").id),
                                  "action" => "add" } ],
      "conducts" => %w[1 9],
      "exam_requests" => [ { "sigtap_code" => "0202010503", "label" => "DOSAGEM DE HEMOGLOBINA GLICOSILADA" },
                           { "sigtap_code" => "0202010317", "label" => ClinicalTerms::SigtapExams.label("0202010317", Time.zone.today.strftime("%Y%m")),
                             "cid10_justification" => "E119" } ]
    )
    expect(changes["evaluated_problems"].sole["label"]).to be_present
    expect(changes["exam_requests"].last["label"]).to be_present
  end

  it "finalizada: itens gravados (sem os do adendo), adendos em ordem com autor e mudanças" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "exame adicional pedido",
                                    text: "Pedido creatinina", changes: { "exam_requests" => [ { "sigtap_code" => "0202010503" }, { "sigtap_code" => "0202010317" } ] })
    json = described_class.consultation(consultation.reload).deep_stringify_keys
    expect(json["evaluated_problems"].sole).to include("problem_id" => PatientProblem.sole.id, "code" => "T90", "action" => "add")
    expect(json["exam_requests"].map { |e| e["sigtap_code"] }).to eq([ "0202010503" ])
    addendum = json["addenda"].sole
    expect(addendum.keys).to match_array(%w[id author_name created_at reason text changes signature])
    expect(addendum.values_at("author_name", "reason", "text")).to eq([ doctor.professional.professional_name, "exame adicional pedido", "Pedido creatinina" ])
    expect(addendum["changes"]["exam_requests"].map { |e| e["sigtap_code"] }).to eq(%w[0202010503 0202010317])
    expect(described_class.summary(consultation).deep_stringify_keys)
      .to include("id" => consultation.id, "author_name" => doctor.professional.professional_name,
                  "care_type_label" => "Consulta no dia", "addenda_count" => 1)
  end
end
