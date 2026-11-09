require "rails_helper"

# Módulo 32a (ADR 0050; contrato §7 e §14 Q10; plano, Desvio 14): o
# atendimento médico na UPA é a consulta do 19a com `kind: "urgency"` — o tipo
# vem do encontro, o paciente é o do atendimento (o provisório inclusive), a
# finalização não fecha o atendimento (quem fecha é o desfecho) e nada vai ao
# LEDI. Prontuário, documentos e sugestão de notificação seguem o 19a.
RSpec.describe "Atendimento médico na UPA", type: :request do
  include ActiveJob::TestHelper

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:encounter) do
    arrived!(upa, unidentified: "Mulher, 30 anos, crise convulsiva").tap { |e| classified!(e, color: "orange", by: nurse, pain_scale: 8) }
  end

  before do
    ciap2_release!; cid10_release!; sigtap_release!
    called!(encounter, by: doctor)
    sign_in_as(doctor)
  end

  it "abre a consulta urgency do provisório, finaliza sem fechar o atendimento e sem LEDI" do
    json_post "/attendance/attendances/#{encounter.attendance_id}/consultation", {}
    expect(response).to have_http_status(:created)
    consultation = Consultation.find(json_body["id"])
    expect(json_body["kind"]).to eq("urgency")
    expect(consultation).to have_attributes(kind: "urgency", patient_id: encounter.patient.id, care_type: nil)
    expect(encounter.reload.consultation_id).to eq(consultation.id)

    json_patch "/attendance/consultations/#{consultation.id}", draft_body(care_type: 5)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to include("error" => "invalid_request", "path" => "care_type")

    json_patch "/attendance/consultations/#{consultation.id}", draft_body(exam_requests: [ { "sigtap_code" => "0202010473" } ]).except("care_type")
    expect(response).to have_http_status(:ok)
    expect(consultation.reload.draft_items["exam_requests"].first["priority"]).to eq("urgent")

    expect { json_post "/attendance/consultations/#{consultation.id}/finalize", {} }
      .not_to have_enqueued_job(Ledi::ConsultationFichaJob)
    expect(response).to have_http_status(:ok)
    expect(consultation.reload).to be_finalized
    expect(consultation.care_type).to be_nil
    expect(consultation.exam_requests.sole.priority).to eq("urgent")
    expect(encounter.attendance.reload.status).to eq("in_care")
    expect(encounter.reload.state).to eq("in_care")
    get "/urgency/queue", params: { health_unit_id: upa.id }
    expect(json_body["in_care"].sole).to include("encounter_id" => encounter.id, "consultation_id" => consultation.id,
                                                 "consultation_status" => "finalized")

    json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: "discharged"
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to include("error" => "invalid_request", "path" => "outcome")
  end

  it "finalizar a urgência com o desfecho do 13 no corpo é recusado sem mudar nada" do
    consultation = urgency_consultation!(encounter, doctor: doctor)
    json_patch "/attendance/consultations/#{consultation.id}", draft_body.except("care_type")
    json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "discharged" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to include("error" => "invalid_request", "path" => "outcome")
    expect(consultation.reload).to be_draft
  end

  it "kind errado e consulta urgency fora da UPA são recusados" do
    json_post "/attendance/attendances/#{encounter.attendance_id}/consultation", kind: "general"
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to include("error" => "invalid_request", "path" => "kind")
    json_post "/attendance/attendances/#{encounter.attendance_id}/consultation", kind: "dental"
    expect(json_body).to include("error" => "invalid_request", "path" => "kind")
    expect(Consultation.count).to eq(0)

    ubs = create_unit("UBS Z")
    attendance = consulting_attendance!(ubs, citizen: verified_citizen!(1), doctor: doctor!(ubs))
    sign_in_as(attendance.called_by_user)
    json_post "/attendance/attendances/#{attendance.id}/consultation", kind: "urgency"
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["path"]).to eq("kind")
    json_post "/attendance/attendances/#{attendance.id}/consultation", {}
    expect(response).to have_http_status(:created)
    expect(json_body["kind"]).to eq("general")
  end

  it "urgency_care desligado: 403 feature_disabled urgency_care" do
    Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    json_post "/attendance/attendances/#{encounter.attendance_id}/consultation", {}
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
  end

  it "prontuário em contexto pelo walk_in; vigilância sugere notificação pelo CID; atestado do provisório sai" do
    surveillance_city!
    documents_city!
    get "/attendance/attendances/#{encounter.attendance_id}/record"
    expect(response).to have_http_status(:ok)
    expect(json_body.dig("patient", "id")).to eq(encounter.patient.id)
    expect(json_body.dig("patient", "display_name")).to eq("Paciente não identificado")
    expect(json_body["access"]).to eq("in_context")

    consultation = urgency_consultation!(encounter, doctor: doctor)
    json_patch "/attendance/consultations/#{consultation.id}",
               draft_body(evaluated_problems: [ { "action" => "add", "terminology" => "cid10", "code" => "A90" } ]).except("care_type")
    expect(response).to have_http_status(:ok)
    get "/attendance/consultations/#{consultation.id}/notification_suggestions"
    expect(json_body["suggestions"].map { |s| s["matched_code"] }).to include("A90")

    json_post "/attendance/consultations/#{consultation.id}/documents", kind: "sick_note", content: { type: "leave", days: 1 }
    expect(response).to have_http_status(:created)
    document = ClinicalDocument.find(json_body["id"])
    expect(document).to have_attributes(patient_id: encounter.patient.id, citizen_id: nil, attendance_id: encounter.attendance_id)
  end

  it "declaração de comparecimento do walk_in sai pelo paciente; documento sem cidadão fora do walk_in é recusado no banco" do
    documents_city!
    json_post "/attendance/attendances/#{encounter.attendance_id}/declarations", content: {}, health_unit_id: upa.id
    expect(response).to have_http_status(:created)
    expect(ClinicalDocument.find(json_body["id"])).to have_attributes(patient_id: encounter.patient.id, citizen_id: nil)

    ubs = create_unit("UBS W")
    attendance = consulting_attendance!(ubs, citizen: verified_citizen!(2), doctor: doctor!(ubs))
    patient = urgency_patient!(urgency_seq!)
    expect do
      ApplicationRecord.transaction(requires_new: true) do
        ClinicalDocument.create!(kind: "attendance_declaration", patient_id: patient.id, citizen_id: nil, attendance: attendance,
                                 author_user_id: doctor.id, issue_mode: "paper", verification_token: ClinicalDocuments::Codes.token,
                                 short_code: ClinicalDocuments::Codes.short_code, issued_at: Time.current, content: "{}")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /without citizen belongs to a walk_in/)
  end

  it "o walk_in em contexto não abre o prontuário de outro paciente" do
    other = urgency_patient!(urgency_seq!)
    grant = ClinicalRecord::Access.call(user: doctor, patient: other, attendance: encounter.attendance)
    expect(grant.allowed?).to be(false)
    grant = ClinicalRecord::Access.call(user: doctor, patient: encounter.patient)
    expect(grant.kind).to eq(:in_context)
  end

  describe "opções da consulta (§14 Q10)" do
    it "médico só da UPA recebe kinds [urgency]; o da UBS, [general]; desligado, a UPA volta ao 13" do
      get "/attendance/consultation_options"
      expect(json_body["kinds"]).to eq([ "urgency" ])

      ubs = create_unit("UBS Y")
      sign_in_as(doctor!(ubs))
      get "/attendance/consultation_options"
      expect(json_body["kinds"]).to eq([ "general" ])

      Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      sign_in_as(doctor)
      get "/attendance/consultation_options"
      expect(json_body["kinds"]).to eq([ "general" ])
    end

    it "médico com vínculo na UPA e na UBS recebe general e urgency" do
      link_professional!(doctor, create_unit("UBS X"))
      get "/attendance/consultation_options"
      expect(json_body["kinds"]).to eq(%w[general urgency])
    end
  end
end
