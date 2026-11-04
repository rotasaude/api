require "rails_helper"

# Módulo 31 (contrato §4, §9, §15 P8, P28, P29; plano, Desvio 12): a receita,
# o registro da Notificação e o atestado do 19 emitidos pela ação do CAPS —
# sem atendimento e sem cidadão, fora da lista de medicamentos, assinados pelo
# 19b com o CAPS no cabeçalho, lidos/impressos/cancelados pelas rotas do 19 só
# por quem está lotado no CAPS (os demais, 404) e fora do wpda, da linha do
# tempo e do "reaproveitar o último" da UBS.
RSpec.describe "CAPS — documentos da ação", type: :request do
  before do
    psychosocial_sigtap!
    controlled_city!(mock: true, signature: true)
    ciap2_release!; cid10_release!; sigtap_release!
    Platform::Features.set!(city: Current.city, key: "psychosocial_care", enabled: true, maintainer: ledi_maintainer!)
    PsychosocialSetting.ensure_defaults!
    CityCatalog.reset_cache!
    city_profile!
    import_test_catalog!
  end

  let(:caps) { caps! }
  let(:psychiatrist) do
    caps_staff!(caps, cbo: "225133").tap do |user|
      user.professional.update!(cpf: SignatureHelpers::DOCTOR_CPF)
      prescriber_contact!(user)
    end
  end
  let(:enrollment) { enrollment!(caps, reference: psychiatrist) }
  let(:patient) { enrollment.patient }
  let(:action) { record_action!(caps, psychiatrist, participants: [ { enrollment_id: enrollment.id } ]) }
  let(:fluoxetina) { controlled_item!(code: 9_900_001, ingredient: "FLUOXETINA", list: "C1") }
  let(:viewed) { DomainEvent.where(name: "clinical_record.viewed") }
  let(:leave) { { "type" => "leave", "days" => 3 } }

  def rce
    { "items" => [ { "catalog_item" => { "id" => fluoxetina.id }, "quantity" => 30, "quantity_unit" => "cápsula", "route" => "oral",
                     "dosage_instructions" => "1 cápsula pela manhã", "duration_days" => 30, "continuous" => true } ],
      "patient_identification" => patient_identification }
  end

  def notification
    { "notification_type" => "B", "paper_number" => "PR-1234567", "numbering_uf" => "PR",
      "item" => { "catalog_item" => { "id" => controlled_item!(code: 9_900_003, ingredient: "DIAZEPAM", list: "B1").id },
                  "quantity" => 30, "quantity_unit" => "comprimido", "route" => "oral",
                  "dosage_instructions" => "1 comprimido à noite", "duration_days" => 30 } }
  end

  def post_document(kind, content, on: action, **extra)
    json_post "/psychosocial/actions/#{on.id}/documents", { kind: kind, content: content }.merge(extra)
  end

  def sick_note!(by: psychiatrist, on: action)
    sign_in_as(by)
    post_document("sick_note", leave, on: on)
    raise "atestado recusado: #{response.body}" unless response.status == 201

    ClinicalDocument.find(json_body["id"])
  end

  describe "POST /psychosocial/actions/:id/documents" do
    it "receita controlada digital pela ação: sem atendimento e sem cidadão, fora da lista de medicamentos, assinada com o CAPS" do
      stub_psc!
      stub_signer!
      linked_certificate!(psychiatrist, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
      sncr_stock!(psychiatrist, kind: "rce", count: 2)
      action
      sign_in_as(psychiatrist)
      issued = DomainEvent.where(name: "clinical_document.issued")

      expect { post_document("prescription", rce) }.not_to change(PatientMedication, :count)
      expect(response).to have_http_status(:created)
      expect(json_body).to include("kind" => "prescription", "issue_mode" => "digital", "paper_reason" => nil,
                                   "attendance_id" => nil, "consultation_id" => nil)
      expect(json_body.dig("signature", "mode")).to eq("pending")
      document = ClinicalDocument.find(json_body["id"])
      expect(document).to have_attributes(psychosocial_action_id: action.id, attendance_id: nil, citizen_id: nil,
                                          patient_id: patient.id, cbo_code: "225133", author_user_id: psychiatrist.id)
      expect(document.content_data.dig("sncr", "number")).to be_present
      expect(issued.last.payload).to eq("document_id" => document.id, "kind" => "prescription", "psychosocial_action_id" => action.id,
                                        "issue_mode" => "digital", "category" => "special_control")
      request = document.signature_request
      expect(request).to have_attributes(consultation_id: nil, status: "pending")
      expect(Signatures::Json.requests([ request ]).sole).to include(document_type: "clinical_document", consultation_id: nil,
                                                                    patient_display_name: patient.display_name)

      signature = sign_document!(document, author: psychiatrist)
      canonical = JSON.parse(signature.canonical_json)
      expect(canonical).to include("schema" => "rotasaude.clinical_document.v1")
      expect(canonical["unit"]).to eq("cnes" => caps.cnes, "name" => caps.name)
      expect(canonical.dig("professional", "cbo_code")).to eq("225133")

      get "/attendance/documents/#{document.id}/print"
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      get "/v/#{document.verification_token}", headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("kind" => "prescription", "unit" => caps.name, "status" => "valid", "mode" => "digital")
      expect(PatientMedication.where(patient_id: patient.id)).to be_empty
    end

    it "registro da Notificação: papel, sem lista de medicamentos; atestado sem certificado sai em papel" do
      sign_in_as(psychiatrist)
      expect { post_document("controlled_notification_record", notification) }.not_to change(PatientMedication, :count)
      expect(response).to have_http_status(:created)
      expect(ClinicalDocument.find(json_body["id"])).to have_attributes(issue_mode: "paper", citizen_id: nil, attendance_id: nil)
      post_document("sick_note", leave)
      expect(json_body).to include("issue_mode" => "paper", "paper_reason" => "no_certificate")
      expect(PatientMedicationEvent.count).to eq(0)
    end

    it "psicóloga, ação coletiva, outra autora, ação cancelada e tipo fora do CAPS são recusados sem gravar" do
      psychologist = caps_staff!(caps, cbo: "251510")
      other = enrollment!(caps, reference: psychiatrist)
      own = record_action!(caps, psychologist, participants: [ { enrollment_id: enrollment.id } ])
      group = record_action!(caps, psychiatrist, sigtap_code: "0301080216",
                                                 participants: [ { enrollment_id: enrollment.id }, { enrollment_id: other.id } ])
      cancelled = record_action!(caps, psychiatrist, participants: [ { enrollment_id: enrollment.id } ])
      Psychosocial::CancelAction.call(action: cancelled, reason: "Lançada em duplicidade no dia", by: psychiatrist)

      sign_in_as(psychologist)
      expect { post_document("sick_note", leave, on: own) }.not_to change(ClinicalDocument, :count)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "prescriber_required" } ])
      post_document("sick_note", leave, on: action)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])

      sign_in_as(psychiatrist)
      post_document("sick_note", leave, on: group)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "prescriber_required" } ])
      post_document("sick_note", leave, on: cancelled)
      expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_cancelled" } ])
      %w[exam_requisition attendance_declaration nope].each do |kind|
        post_document(kind, {})
        expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "kind" } ])
      end
      json_post "/psychosocial/actions/#{action.id}/documents", kind: "sick_note", content: leave, citizen_id: SecureRandom.uuid
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "citizen_id" ])
      expect(ClinicalDocument.count).to eq(0)
    end

    it "CAPS não lotado → 404; sem o papel do CAPS → 403; interruptores desligados → 403 feature_disabled" do
      action
      sign_in_as(caps_staff!(caps!, cbo: "225133"))
      post_document("sick_note", leave)
      expect(response).to have_http_status(:not_found)
      ubs = HealthUnit.create!(name: "UBS Vila", kind: "ubs")
      sign_in_as(ubs_doctor!(ubs))
      post_document("sick_note", leave)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])

      sign_in_as(psychiatrist)
      Platform::Features.set!(city: Current.city, key: "clinical_documents", enabled: false, maintainer: ledi_maintainer!)
      post_document("sick_note", leave)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "clinical_documents" } ])
      Platform::Features.set!(city: Current.city, key: "psychosocial_care", enabled: false, maintainer: ledi_maintainer!)
      get "/psychosocial/actions/#{action.id}/documents"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "feature_disabled", "feature" => "psychosocial_care" } ])
    end

    it "cancelar e emitir outro só substitui documento cancelado da mesma ação" do
      first = sick_note!
      ClinicalDocuments::Cancel.call(document_id: first.id, by: psychiatrist, reason: "Dias de afastamento errados")
      other = record_action!(caps, psychiatrist, participants: [ { enrollment_id: enrollment.id } ])
      post_document("sick_note", leave, on: other, replaces_document_id: first.id)
      expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_content", "field" => "replaces_document_id" } ])
      post_document("sick_note", leave, replaces_document_id: first.id)
      expect(response).to have_http_status(:created)
      expect(json_body["replaces_document_id"]).to eq(first.id)
    end
  end

  describe "GET /psychosocial/actions/:id/documents" do
    it "lista os documentos da ação para a equipe lotada, com a trilha documents do paciente" do
      document = sick_note!
      colleague = caps_staff!(caps, cbo: "251510")
      sign_in_as(colleague)
      expect { get "/psychosocial/actions/#{action.id}/documents" }.to change(viewed, :count).by(1)
      expect(json_body["items"].map { |item| [ item["id"], item["signature"] ] }).to eq([ [ document.id, nil ] ])
      expect(viewed.last.payload).to include("patient_id" => patient.id, "user_id" => colleague.id, "access" => "psychosocial",
                                             "resource" => "documents")
      get "/psychosocial/actions/#{action.id}/documents?health_unit_id=#{caps.id}"
      expect([ response.status, json_body["path"] ]).to eq([ 422, "health_unit_id" ])
    end
  end

  describe "rotas do 19 (/attendance/documents/:id)" do
    it "a equipe lotada lê e imprime (trilha do CAPS); a autora cancela com step-up" do
      document = sick_note!
      colleague = caps_staff!(caps, cbo: "251510")
      sign_in_as(colleague)
      expect { get "/attendance/documents/#{document.id}" }.to change(viewed, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(json_body).to include("id" => document.id, "attendance_id" => nil, "consultation_id" => nil)
      expect(viewed.last.payload).to include("access" => "psychosocial", "resource" => "documents", "patient_id" => patient.id)
      get "/attendance/documents/#{document.id}/print?health_unit_id=#{caps.id}"
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])

      stepped_up!(colleague)
      json_post "/attendance/documents/#{document.id}/cancel", reason: "Emitido para o paciente errado"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
      stepped_up!(psychiatrist)
      json_post "/attendance/documents/#{document.id}/cancel", reason: "Emitido para o paciente errado", health_unit_id: caps.id
      expect([ response.status, json_body["status"] ]).to eq([ 200, "cancelled" ])
    end

    it "médico da UBS em contexto e equipe de outro CAPS não leem, não imprimem nem cancelam (404)" do
      document = sick_note!
      ubs = HealthUnit.create!(name: "UBS Vila", kind: "ubs")
      doctor = ubs_doctor!(ubs)
      in_context!(doctor, ubs, patient)
      stranger = caps_staff!(caps!, cbo: "225133")
      [ doctor, stranger ].each do |user|
        stepped_up!(user)
        get "/attendance/documents/#{document.id}"
        expect(response).to have_http_status(:not_found)
        get "/attendance/documents/#{document.id}/print"
        expect(response).to have_http_status(:not_found)
        json_post "/attendance/documents/#{document.id}/cancel", reason: "Tentativa de cancelar de fora"
        expect(response).to have_http_status(:not_found)
      end
      expect(document.reload).to be_issued
      expect(viewed.where("payload->>'user_id' IN (?)", [ doctor.id, stranger.id ])).to be_empty
    end

    it "sem o papel do CAPS, documento comum continua exigindo health_professional" do
      unit = create_unit
      doctor = doctor!(unit)
      consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(99))
      ubs_document = ClinicalDocuments::Issue.call(kind: "sick_note", content: leave, by: doctor, consultation: consultation)
      expect(ubs_document).to be_ok
      sign_in_as(caps_staff!(caps, cbo: "225133"))
      get "/attendance/documents/#{ubs_document.payload[:document].id}"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  describe "sigilo" do
    it "fora da linha do tempo, dos documentos do cidadão e do reaproveitamento da identificação pela UBS" do
      sign_in_as(psychiatrist)
      post_document("prescription", rce)
      prescription = ClinicalDocument.find(json_body["id"])
      post_document("controlled_notification_record", notification)
      record = ClinicalDocument.find(json_body["id"])
      person = Timeline::Person.for_patient(patient)
      window = { person: person, before: nil, limit: 50, from: nil, to: nil }

      expect(Timeline::Sources::ClinicalDocumentSource.entries(**window)).to be_empty
      expect(Timeline::Sources::ControlledNotificationSource.entries(**window)).to be_empty
      [ prescription, record ].each { |document| expect(Timeline::CitizenDocuments.find(person: person, id: document.id)).to be_nil }

      ubs = HealthUnit.create!(name: "UBS Vila", kind: "ubs")
      doctor = ubs_doctor!(ubs)
      consultation = finalized_consultation!(unit: ubs, doctor: doctor, citizen: Citizen.find_by!(patient_id: patient.id))
      sign_in_as(doctor)
      get "/attendance/consultations/#{consultation.id}/patient_identification"
      expect([ response.status, json_body ]).to eq([ 200, { "patient_identification" => nil } ])
    end
  end

  describe "banco (900004)" do
    let(:base) do
      { kind: "sick_note", author_user_id: psychiatrist.id, cbo_code: "225133", issue_mode: "paper", issued_at: Time.current,
        content: "{}", verification_token: ClinicalDocuments::Codes.token, short_code: ClinicalDocuments::Codes.public_short_code,
        patient_id: patient.id }
    end

    def insert!(**attrs) = ApplicationRecord.transaction(requires_new: true) { ClinicalDocument.create!(base.merge(attrs)) }

    it "o documento do CAPS: só a ação, sem cidadão, sem consulta, com CBO; digital só se assina como documento clínico" do
      ubs = HealthUnit.create!(name: "UBS Vila", kind: "ubs")
      attendance = walk_in_attendance!(ubs, citizen: Citizen.find_by!(patient_id: patient.id))
      expect { insert!(psychosocial_action_id: action.id, attendance_id: attendance.id) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_parent/)
      expect { insert!(psychosocial_action_id: action.id, citizen_id: attendance.citizen_id) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_citizen/)
      expect { insert!(attendance_id: attendance.id, citizen_id: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_citizen/)
      expect { insert!(psychosocial_action_id: action.id, cbo_code: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_cbo_required/)
      expect { insert!(citizen_id: attendance.citizen_id, kind: "attendance_declaration", cbo_code: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_clinical_documents_parent/)
      document = insert!(psychosocial_action_id: action.id, issue_mode: "digital")
      other = record_action!(caps, psychiatrist, participants: [ { enrollment_id: enrollment.id } ])
      expect { ApplicationRecord.transaction(requires_new: true) { document.update_columns(psychosocial_action_id: other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /never changes/)

      request = ->(type, consultation_id) do
        ApplicationRecord.transaction(requires_new: true) do
          SignatureRequest.create!(document_type: type, document_id: SecureRandom.uuid, consultation_id: consultation_id,
                                   author_user_id: psychiatrist.id)
        end
      end
      expect { request.call("ClinicalDocument", nil) }.not_to raise_error
      expect { request.call("Consultation", nil) }.to raise_error(ActiveRecord::StatementInvalid, /ck_signature_requests_consultation/)
      expect { request.call("ConsultationAddendum", nil) }.to raise_error(ActiveRecord::StatementInvalid, /ck_signature_requests_consultation/)
      expect { request.call("LabReport", SecureRandom.uuid) }.to raise_error(ActiveRecord::StatementInvalid, /ck_signature_requests_consultation/)
    end
  end
end
