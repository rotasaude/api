require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_include, :include

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

  # Nome e modalidade que nunca saem na verificação pública nem no atestado (P48).
  let(:caps) { caps!(name: "CAPS AD III Centro Vida", modality: "caps_ad_iii") }
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
  let(:hidden) { [ "Centro Vida", "AD III", "caps_ad_iii" ] }
  # P49: no atestado do CAPS, só profissão e registro — nunca CBO, especialidade ou título.
  let(:specialty) { [ "225133", "psiquiatra", "Psiquiatra", "CBO" ] }
  def professional_line = "Médico — CRM #{psychiatrist.professional.registration_number}/#{psychiatrist.professional.council_state}"

  def pdf_text(bytes) = PDF::Reader.new(StringIO.new(bytes.split(FakeSigner::MARKER).first)).pages.map(&:text).join("\n")

  def verification_bodies(document)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    get "/v/#{document.verification_token}", headers: { "Accept" => "application/json" }
    json = [ response.status, response.body ]
    get "/v/#{document.verification_token}"
    [ json, [ response.status, response.body ] ]
  end

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
      expect(json_body).to include("kind" => "prescription", "status" => "valid", "mode" => "digital",
                                   "unit" => "Centro de Atenção Psicossocial — #{city_profile!.name} — CNES #{caps.cnes}")
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

  describe "assinatura pelas rotas do 19b, só com o papel do CAPS (P28, ruling b)" do
    before do
      stub_psc!
      stub_signer!
    end

    def callback!(url)
      state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
      json_post "/signature/oauth/callback", state: state, code: authorize_and_approve!(url)
      expect(response).to have_http_status(:ok)
    end

    it "vincula o certificado, lista, volta ao papel e assina pelo lote; o impresso sai assinado" do
      expect(psychiatrist.has_role?("health_professional")).to be(false)
      stepped_up!(psychiatrist)
      json_post "/signature/certificates/link", provider: "vidaas", return_to: "/caps"
      callback!(json_body.fetch("authorize_url"))
      expect(SignerCertificate.active.where(user_id: psychiatrist.id)).to exist

      first, second = Array.new(2) { sick_note! }
      expect([ first, second ].map(&:issue_mode)).to eq(%w[digital digital])
      stale = signature_request!(author: psychiatrist) # pedido de consulta do mesmo usuário (ex.: papel antigo)
      get "/signature/requests"
      expect(json_body["items"].map { |item| item["document_id"] }).to eq([ first.id, second.id ])
      expect(json_body["items"].first).to include("document_type" => "clinical_document", "consultation_id" => nil,
                                                  "patient_display_name" => patient.display_name)

      json_post "/signature/requests/#{second.signature_request.id}/return_to_paper", reason: "Paciente pediu o papel hoje"
      expect([ response.status, json_body["status"] ]).to eq([ 200, "returned_to_paper" ])
      expect(second.reload.issue_mode).to eq("paper")
      json_post "/signature/requests/#{stale.id}/return_to_paper", reason: "Paciente pediu o papel hoje"
      expect([ response.status, json_body["error"] ]).to eq([ 404, "not_found" ])

      json_post "/signature/batches", request_ids: [ first.signature_request.id, stale.id ], return_to: "/caps"
      expect(json_body["count"]).to eq(1)
      callback!(json_body.fetch("authorize_url"))
      signature = first.signature_request.reload.signature
      expect(first.signature_request.status).to eq("signed")
      expect(stale.reload.status).to eq("pending")
      get "/attendance/documents/#{first.id}/print"
      expect([ response.status, response.body.b ]).to eq([ 200, signature.signed_pdf_bytes.b ])
    end

    it "outra pessoa da equipe do CAPS e o médico da UBS não veem nem mexem no pedido do CAPS" do
      linked_certificate!(psychiatrist, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
      request = sick_note!.signature_request
      colleague = caps_staff!(caps, cbo: "225133").tap { |user| user.professional.update!(cpf: SignatureHelpers::OTHER_CPF) }
      linked_certificate!(colleague, leaf: fake_psc.leaf(SignatureHelpers::OTHER_CPF))
      doctor = ubs_doctor!(HealthUnit.create!(name: "UBS Vila", kind: "ubs"))
      [ colleague, doctor ].each do |user|
        sign_in_as(user)
        get "/signature/requests"
        expect([ response.status, json_body["items"] ]).to eq([ 200, [] ])
        json_post "/signature/requests/#{request.id}/return_to_paper", reason: "Paciente pediu o papel hoje"
        expect([ response.status, json_body["error"] ]).to eq([ 403, "not_author" ])
      end
      sign_in_as(colleague)
      json_post "/signature/batches", request_ids: [ request.id ], return_to: "/"
      expect([ response.status, json_body["error"] ]).to eq([ 409, "nothing_pending" ])
      expect(request.reload.status).to eq("pending")
    end

    it "Mode.blocks acha o pedido do documento do CAPS sem carregar pedidos de laudo (consultation_id nulo)" do
      linked_certificate!(psychiatrist, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
      document = sick_note!
      SignatureRequest.create!(document_type: "LabReport", document_id: SecureRandom.uuid, consultation_id: nil,
                               author_user_id: psychiatrist.id)
      loaded = []
      subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        loaded << payload[:record_count] if payload[:class_name] == "SignatureRequest"
      end
      blocks = Signatures::Mode.blocks([ document ])
      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(blocks.fetch([ "ClinicalDocument", document.id ])).to include(mode: "pending", request_id: document.signature_request.id)
      expect(loaded).to eq([ 1 ])
    end
  end

  # P56 (R10): /sncr/* aceita a equipe do CAPS (padrão do P47); o estoque é de
  # quem pediu e só sai na emissão de um documento de que ela é autora. O
  # documento digital com número SNCR do CAPS é a receita de controle especial
  # (RCE): o registro da Notificação é sempre em papel.
  describe "números SNCR da equipe do CAPS (P56, R10)" do
    before { stub_sncr_mock! }

    def stock_of(kind = "rce") = (get("/sncr/stock") && json_body[kind])

    it "a autora do CAPS pede o bloco pelo /sncr, vê o saldo e o número sai na receita controlada digital pela ação" do
      stub_psc!
      stub_signer!
      linked_certificate!(psychiatrist, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
      action
      sign_in_as(psychiatrist)
      json_post "/sncr/requests", kind: "rce", return_to: "/dashboard/minha-conta/sncr"
      expect(response).to have_http_status(:ok)
      url = URI.decode_www_form(URI(json_body["authorize_url"]).query).to_h.fetch("client_url")
      json_post "/sncr/oauth/callback", state: json_body["state"], session_id: fake_sncr.approve!(url)
      expect([ response.status, json_body["received"] ]).to eq([ 200, 1000 ])
      expect(stock_of).to include("free" => 1000, "used" => 0)

      post_document("prescription", rce)
      expect([ response.status, json_body["issue_mode"] ]).to eq([ 201, "digital" ])
      document = ClinicalDocument.find(json_body["id"])
      number = SncrNumber.find_by!(document_id: document.id)
      expect(number).to have_attributes(user_id: psychiatrist.id, status: "used")
      expect(document.content_data.dig("sncr", "number")).to eq(number.number)
      expect(stock_of).to include("free" => 999, "used" => 1)
    end

    it "outro membro do CAPS não obtém número pela ação da autora; a UBS não vê o estoque do CAPS" do
      sncr_stock!(psychiatrist, kind: "rce", count: 2)
      colleague = caps_staff!(caps, cbo: "225133")
      sncr_stock!(colleague, kind: "rce", count: 1)
      action

      sign_in_as(colleague)
      expect(stock_of).to include("free" => 1, "used" => 0)
      expect { post_document("prescription", rce) }.not_to change(ClinicalDocument, :count)
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
      expect(SncrNumber.where(status: "used")).not_to exist

      ubs = create_unit("UBS Boa Vista")
      sign_in_as(doctor!(ubs))
      expect(stock_of).to include("free" => 0, "used" => 0)
      post_document("prescription", rce)
      expect(response).to have_http_status(:forbidden)
      expect(SncrNumber.where(user_id: psychiatrist.id, status: "free").count).to eq(2)
    end

    it "papel fora do CAPS e sem health_professional continua sem /sncr" do
      sign_in_as(staff_with("viewer-#{SecureRandom.hex(3)}@cidade.gov.br", "viewer"))
      get "/sncr/stock"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "missing_role" } ])
    end
  end

  describe "cancelamento pela coordenação do CAPS (P47)" do
    it "a coordenação lotada cancela o documento de outra profissional, com trilha e o número SNCR anulado" do
      linked_certificate!(psychiatrist, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
      sncr_stock!(psychiatrist, kind: "rce", count: 1)
      sign_in_as(psychiatrist)
      post_document("prescription", rce)
      document = ClinicalDocument.find(json_body["id"])
      expect(SncrNumber.find_by!(document_id: document.id).status).to eq("used")
      lead = caps_staff!(caps, cbo: "223505", lead: true)
      stepped_up!(lead)
      json_post "/attendance/documents/#{document.id}/cancel", reason: "curto"
      expect([ response.status, json_body["error"] ]).to eq([ 422, "invalid_reason" ])
      expect { json_post "/attendance/documents/#{document.id}/cancel", reason: "Receita emitida na ação errada" }
        .to change(viewed, :count).by(1)
      expect([ response.status, json_body["status"] ]).to eq([ 200, "cancelled" ])
      expect(document.reload).to have_attributes(status: "cancelled", cancelled_by_user_id: lead.id)
      expect(SncrNumber.find_by!(document_id: document.id).status).to eq("voided")
      expect(viewed.last.payload).to include("user_id" => lead.id, "access" => "psychosocial", "resource" => "documents")
    end

    it "coordenação de outro CAPS → 404; equipe que não é a autora → 403 not_author" do
      document = sick_note!
      stepped_up!(caps_staff!(caps!, cbo: "223505", lead: true))
      json_post "/attendance/documents/#{document.id}/cancel", reason: "Tentativa de cancelar de fora"
      expect(response).to have_http_status(:not_found)
      stepped_up!(caps_staff!(caps, cbo: "251510"))
      json_post "/attendance/documents/#{document.id}/cancel", reason: "Tentativa de cancelar sem ser a autora"
      expect([ response.status, json_body ]).to eq([ 403, { "error" => "not_author" } ])
      expect(document.reload).to be_issued
    end
  end

  describe "unidade genérica (P48)" do
    it "verificação pública dos três tipos sem nome nem modalidade do CAPS" do
      sign_in_as(psychiatrist)
      post_document("prescription", rce)
      prescription = ClinicalDocument.find(json_body["id"])
      post_document("controlled_notification_record", notification)
      record = ClinicalDocument.find(json_body["id"])
      note = sick_note!
      [ note, prescription ].each do |document|
        (json_status, json), (html_status, html) = verification_bodies(document)
        expect([ json_status, html_status ]).to eq([ 200, 200 ])
        expect(JSON.parse(json)["unit"]).to eq("Centro de Atenção Psicossocial — #{city_profile!.name} — CNES #{caps.cnes}")
        [ json, html ].each { |body| expect(body).to include("Atenção Psicossocial").and(not_include(*hidden)) }
      end
      (_, json), (_, html) = verification_bodies(note)
      expect(JSON.parse(json)["professional"]).to eq("name" => psychiatrist.professional.professional_name, "council" => professional_line)
      [ json, html ].each { |body| expect(body).to include(professional_line).and(not_include(*specialty)) }
      (json_status, json), (html_status, html) = verification_bodies(record) # a Notificação não tem conferência pública
      expect([ json_status, html_status ]).to eq([ 404, 404 ])
      [ json, html ].each { |body| expect(body).not_to include(*hidden) }
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      json_post "/v/lookup", short_code: note.short_code, birth_year: patient.birth_date.to_s[0, 4]
      expect(json_body["unit"]).to start_with("Centro de Atenção Psicossocial")
      expect(json_body.dig("professional", "council")).to eq(professional_line)
    end

    it "atestado impresso e assinado sem o nome; receita impressa com a identificação completa" do
      stub_psc!
      stub_signer!
      paper = sick_note!
      get "/attendance/documents/#{paper.id}/print"
      expect(pdf_text(response.body)).to include("Centro de Atenção Psicossocial", "CNES #{caps.cnes}", professional_line)
        .and(not_include(*hidden, *specialty))

      linked_certificate!(psychiatrist, leaf: fake_psc.leaf(SignatureHelpers::DOCTOR_CPF))
      digital = sick_note!
      signature = sign_document!(digital, author: psychiatrist)
      expect(JSON.parse(signature.canonical_json)["unit"]).to eq("cnes" => caps.cnes, "name" => "Centro de Atenção Psicossocial")
      expect(signature.canonical_json).not_to include(*hidden)
      expect(pdf_text(signature.signed_pdf_bytes)).to include("Centro de Atenção Psicossocial", professional_line)
        .and(not_include(*hidden, *specialty))

      sign_in_as(psychiatrist)
      post_document("prescription", rce) # sem número SNCR no estoque: papel
      expect(json_body["paper_reason"]).to eq("no_sncr_number")
      get "/attendance/documents/#{json_body['id']}/print"
      expect(pdf_text(response.body)).to include("CAPS AD III Centro Vida", "CBO 225133 Médico psiquiatra",
                                                 "CRM-PR #{psychiatrist.professional.registration_number}")
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
      # Módulo 32a (900005): sem cidadão só no walk_in da UPA — fora dele, o trigger recusa.
      expect { insert!(attendance_id: attendance.id, citizen_id: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /without citizen belongs to a walk_in attendance or a CAPS action/)
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
