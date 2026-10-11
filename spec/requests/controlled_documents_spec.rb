require "rails_helper"

# Contrato §2/§12: a emissão grava e devolve paper_reason (no POST e em toda
# leitura); erros novos com status e campo; a última identificação do paciente
# para "reaproveitar o último" (autora da consulta, regra do prontuário).
RSpec.describe "Receita controlada pela API", type: :request do
  before do
    controlled_city!(mock: true)
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit).tap { |user| prescriber_contact!(user) } }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:fluoxetina) { controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1") }
  def body = JSON.parse(response.body)

  def rce(**over)
    { "items" => [ { "catalog_item" => { "id" => fluoxetina.id }, "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral",
                     "dosage_instructions" => "1 cápsula pela manhã", "duration_days" => 30 } ],
      "patient_identification" => patient_identification }.merge(over.stringify_keys)
  end

  def post_document(content, kind: "prescription")
    post "/attendance/consultations/#{consultation.id}/documents", params: { kind: kind, content: content }, as: :json
  end

  it "201 com paper_reason gravado e devolvido na leitura; a última identificação volta para a próxima receita" do
    sign_in_as(doctor)
    get "/attendance/consultations/#{consultation.id}/patient_identification"
    expect([ response.status, body ]).to eq([ 200, { "patient_identification" => nil } ])
    post_document(rce)
    expect(response).to have_http_status(:created)
    expect(body).to include("issue_mode" => "paper", "paper_reason" => "no_certificate")
    expect(ClinicalDocument.find(body["id"]).paper_reason).to eq("no_certificate")
    get "/attendance/documents/#{body['id']}"
    expect(body["paper_reason"]).to eq("no_certificate")
    get "/attendance/consultations/#{consultation.id}/documents"
    expect(body["items"].first["paper_reason"]).to eq("no_certificate")
    expect(body["items"].first["content"]).to include("category" => "special_control", "sncr" => nil)
    log = capture_log { get "/attendance/consultations/#{consultation.id}/patient_identification" }
    expect(body["patient_identification"]).to eq("cpf" => consultation.patient.cpf, "address" => ControlledPrescriptionHelpers::ADDRESS)
    expect(log).not_to include(consultation.patient.cpf, "Araucárias")
  end

  it "GET do documento: sncr null na RCE que voltou ao papel; a digital cancelada continua mostrando (FW1)" do
    signer = signer_doctor!(unit).tap { |user| prescriber_contact!(user); linked_certificate!(user) }
    sncr_stock!(signer, kind: "rce", count: 2)
    issue = lambda do |citizen|
      ClinicalDocuments::Issue.call(kind: "prescription", by: signer, content: rce,
                                    consultation: finalized_consultation!(unit: unit, doctor: signer, citizen: verified_citizen!(citizen))).payload[:document]
    end
    back, cancelled = issue.call(2), issue.call(3)
    expect([ back, cancelled ].map(&:issue_mode)).to eq(%w[digital digital])
    Signatures::ReturnToPaper.call(request_id: back.signature_request.id, by: signer, reason: "Paciente pediu o papel agora")
    ClinicalDocuments::Cancel.call(document_id: cancelled.id, by: signer, reason: "Emitida para o paciente errado")
    expect(back.reload.content_data["sncr"]).to be_present
    sign_in_as(signer)
    get "/attendance/documents/#{back.id}"
    expect([ response.status, body["issue_mode"], body["content"]["sncr"] ]).to eq([ 200, "paper", nil ])
    expect(response.body).not_to include(SncrNumber.find_by(document_id: back.id).number)
    get "/attendance/documents/#{cancelled.id}"
    expect([ body["status"], body["issue_mode"] ]).to eq(%w[cancelled digital])
    expect(body["content"]["sncr"]).to include("number" => SncrNumber.find_by(document_id: cancelled.id).number)
  end

  it "a identificação reaproveitada traz o CPF do cadastro de agora, não o gravado na receita (§12)" do
    sign_in_as(doctor)
    post_document(rce)
    expect(response).to have_http_status(:created)
    # O CPF do paciente é imutável no banco: simula a receita gravada com outro CPF.
    allow_any_instance_of(ClinicalDocument).to receive(:content_data)
      .and_wrap_original { |original| original.call.deep_merge("patient_identification" => { "cpf" => "11144477735" }) }
    get "/attendance/consultations/#{consultation.id}/patient_identification"
    expect(body["patient_identification"]).to eq("cpf" => consultation.patient.cpf, "address" => ControlledPrescriptionHelpers::ADDRESS)
    expect(consultation.patient.cpf).not_to eq("11144477735")
  end

  it "erros com status e campo; nada do paciente no log" do
    sign_in_as(doctor)
    log = capture_log do
      post_document(rce("patient_identification" => patient_identification("address" => ControlledPrescriptionHelpers::ADDRESS.merge("zip" => "80010-000"))))
    end
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_content", "field" => "patient_identification.address.zip" } ])
    post_document(rce("patient_identification" => patient_identification("address" => ControlledPrescriptionHelpers::ADDRESS.merge("district" => "Centro\u0000"))))
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_content", "field" => "patient_identification.address.district" } ])
    post_document(rce("patient_identification" => patient_identification("address" => ControlledPrescriptionHelpers::ADDRESS.merge("city" => "Curitiba\u0007"))))
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_content", "field" => "patient_identification.address.city" } ])
    expect(log).not_to include(consultation.patient.cpf, "Araucárias")
    post_document(rce.merge("items" => rce["items"] * 4))
    expect([ response.status, body["error"] ]).to eq([ 422, "too_many_c1_substances" ])
    doctor.professional.update!(prescriber_address: nil)
    post_document(rce)
    expect([ response.status, body["error"] ]).to eq([ 422, "prescriber_address_missing" ])
  end

  it "registro da Notificação: conteúdo vazio é 422 invalid_content; interruptor desligado: feature_disabled com o interruptor" do
    sign_in_as(doctor)
    post_document({}, kind: "controlled_notification_record")
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_content", "field" => "notification_type" } ])
    Platform::Features.set!(city: Current.city, key: "controlled_prescriptions", enabled: false, maintainer: ledi_maintainer!)
    post_document({}, kind: "controlled_notification_record")
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "controlled_prescriptions" } ])
  end

  it "outra pessoa não lê a identificação; recepção também não" do
    sign_in_as(doctor!(unit))
    get "/attendance/consultations/#{consultation.id}/patient_identification"
    expect([ response.status, body["error"] ]).to eq([ 403, "not_author" ])
    sign_in_as(verifier!)
    get "/attendance/consultations/#{consultation.id}/patient_identification"
    expect([ response.status, body["error"] ]).to eq([ 403, "missing_role" ])
    sign_in_as(doctor)
    get "/attendance/consultations/00000000-0000-4000-8000-000000000000/patient_identification"
    expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
  end
end
