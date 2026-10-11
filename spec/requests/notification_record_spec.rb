require "rails_helper"

# Contrato §3, §7; spec §5: emitido pela autora da consulta, sempre papel,
# sem código nem conferência pública nem impresso; entra na lista de
# medicamentos; cancelável; evento só com ids.
RSpec.describe "Registro da Notificação de papel", type: :request do
  before do
    controlled_city!(mock: true)
    ciap2_release!; cid10_release!; sigtap_release!; city_profile!
    import_test_catalog!
  end

  let(:unit) { create_unit }
  let(:doctor) { signer_doctor!(unit) }
  let(:consultation) { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1)) }
  let(:diazepam) { controlled_item!(code: 9_900_003, ingredient: "DIAZEPAM", list: "B1") }
  def body = JSON.parse(response.body)

  def record!(over = {})
    content = { notification_type: "B", paper_number: "PR-1234567", numbering_uf: "PR",
                item: { catalog_item: { id: diazepam.id }, quantity: 30, quantity_unit: "comprimido", route: "oral",
                        dosage_instructions: "1 comprimido à noite", duration_days: 30 } }.merge(over)
    post "/attendance/consultations/#{consultation.id}/documents", params: { kind: "controlled_notification_record", content: content }, as: :json
  end

  it "registra em papel, sem código, na lista de medicamentos; evento só com ids" do
    linked_certificate!(doctor) # mesmo com certificado, papel
    sign_in_as(doctor)
    record!
    expect(response).to have_http_status(:created)
    expect(body).to include("kind" => "controlled_notification_record", "issue_mode" => "paper", "short_code" => nil,
                            "verification_url" => nil, "signature" => nil, "paper_reason" => nil)
    document = ClinicalDocument.find(body["id"])
    expect(document.signature_request).to be_nil
    medication = PatientMedication.where(patient_id: consultation.patient_id).to_a
    expect(medication.map(&:label).join).to include("DIAZEPAM")
    expect(medication.map(&:continuous)).to eq([ false ])
    event = DomainEvent.where(name: "controlled_notification.recorded").order(:created_at).last
    expect(event.payload).to eq("document_id" => document.id, "notification_type" => "B")

    get "/attendance/documents/#{document.id}/print"
    expect([ response.status, body["error"] ]).to eq([ 404, "not_found" ])
    get "/v/#{document.verification_token}", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:not_found)

    sign_in_as(doctor).update!(mfa_verified_at: Time.current) # step-up do cancelamento (19c)
    post "/attendance/documents/#{document.id}/cancel", params: { reason: "Talão registrado errado" }, as: :json
    expect([ response.status, body["status"] ]).to eq([ 200, "cancelled" ])
  end

  it "recusas 422 com a razão" do
    sign_in_as(doctor)
    record!(notification_type: "A")
    expect([ response.status, body["error"] ]).to eq([ 422, "notification_type_mismatch" ])
    record!(notification_type: "X")
    expect([ response.status, body ]).to eq([ 422, { "error" => "invalid_content", "field" => "notification_type" } ])
  end

  it "enfermeiro: 403 cbo_not_allowed, mesmo com o catálogo da plataforma indisponível" do
    allow(Medications::Search).to receive(:available?).and_return(false)
    nurse = nurse!(unit)
    nurse_consultation = finalized_consultation!(unit: unit, doctor: nurse, citizen: verified_citizen!(2))
    sign_in_as(nurse)
    post "/attendance/consultations/#{nurse_consultation.id}/documents",
         params: { kind: "controlled_notification_record", content: {} }, as: :json
    expect([ response.status, body["error"] ]).to eq([ 403, "cbo_not_allowed" ])
  end

  it "interruptor desligado: 403 feature_disabled com a chave" do
    Platform::Features.set!(city: Current.city, key: "controlled_prescriptions", enabled: false, maintainer: ledi_maintainer!)
    sign_in_as(doctor)
    record!
    expect([ response.status, body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "controlled_prescriptions" } ])
  end
end
