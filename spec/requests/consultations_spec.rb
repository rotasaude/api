require "rails_helper"

# Contratos §4: a consulta em /attendance — iniciar, autosave, finalizar,
# ler (trilha), adendo. Review Focus 3: autosave nas bordas.
RSpec.describe "Consulta", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:attendance) { consulting_attendance!(unit, citizen: citizen, doctor: doctor) }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]
  def json_patch(path, params) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })

  def start!
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{attendance.id}/consultation"
    body
  end

  it "opções da consulta para o usuário" do
    sign_in_as(doctor)
    get "/attendance/consultation_options"
    expect(body["care_types"].map { |t| t["code"] }).to eq(%w[1 2 5 6])
    expect(body["conducts"].first).to eq("code" => "1", "label" => "Retorno para consulta agendada")
    expect(body["cid10_allowed_for_cbo"]).to be(true)
  end

  it "inicia (201), de novo 409 com o id; par não validado 409; interruptor desligado 403" do
    id = start!["id"]
    expect(response).to have_http_status(:created)
    expect(body["status"]).to eq("draft")
    json_post "/attendance/attendances/#{attendance.id}/consultation"
    expect([ response.status, body["error"], body["consultation_id"] ]).to eq([ 409, "already_exists", id ])
    declared = consulting_attendance!(unit, citizen: screening_citizen!(5), doctor: doctor)
    json_post "/attendance/attendances/#{declared.id}/consultation"
    expect(status_and_error).to eq([ 409, "citizen_not_verified" ])
    clinical_city!(enabled: false)
    json_post "/attendance/attendances/#{declared.id}/consultation"
    expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "clinical_record" ])
  end

  it "autosave nas bordas: 422 com field, 403 de outro, 409 depois de finalizar (Review Focus 3)" do
    id = start!["id"]
    json_patch "/attendance/consultations/#{id}", draft_body
    expect(response).to have_http_status(:ok)
    expect(body["evaluated_problems"].sole["code"]).to eq("T90")
    { { "vitals" => { "systolic" => "130" } } => [ 422, "implausible_vital", "diastolic" ],
      { "subjective" => "x" * 20_001 } => [ 422, "text_too_long", "subjective" ],
      { "objective" => { "a" => 1 } } => [ 422, "invalid_text", "objective" ],
      { "conducts" => "9" } => [ 422, "invalid_conduct", nil ],
      { "evaluated_problems" => [ { "action" => "add", "terminology" => "ciap2", "code" => "XYZ" } ] } => [ 422, "invalid_problem", nil ] }
      .each do |params, (status, error, field)|
      json_patch "/attendance/consultations/#{id}", params
      expect([ response.status, body["error"], body["field"] ]).to eq([ status, error, field ]), params.inspect.truncate(80)
    end
    sign_in_as(doctor!(unit, cbo: "223505"))
    json_patch "/attendance/consultations/#{id}", "plan" => "x"
    expect(status_and_error).to eq([ 403, "not_author" ])
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "discharged" }
    expect(response).to have_http_status(:ok)
    json_patch "/attendance/consultations/#{id}", "plan" => "tarde demais"
    expect(status_and_error).to eq([ 409, "not_draft" ])
  end

  # Contrato §4: códigos são "<código>" (string) na entrada e na saída.
  it "códigos como string ponta a ponta: PATCH, finalize e adendo ecoam strings; não numérico 422" do
    id = start!["id"]
    json_patch "/attendance/consultations/#{id}", draft_body(care_type: "5", conducts: [ "9" ])
    expect(response).to have_http_status(:ok)
    expect(body.values_at("care_type", "conducts")).to eq([ "5", [ "9" ] ])
    expect(Consultation.find(id).care_type).to eq(5)
    { { "care_type" => "abc" } => "invalid_care_type", { "care_type" => "5.0" } => "invalid_care_type",
      { "care_type" => "" } => "invalid_care_type", { "conducts" => [ "abc" ] } => "invalid_conduct",
      { "conducts" => [ "" ] } => "invalid_conduct" }.each do |params, error|
      json_patch "/attendance/consultations/#{id}", params
      expect(status_and_error).to eq([ 422, error ]), params.inspect
    end
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "discharged" }
    expect(response).to have_http_status(:ok)
    expect(body.values_at("status", "care_type", "conducts")).to eq([ "finalized", "5", [ "9" ] ])
    json_post "/attendance/consultations/#{id}/addenda", reason: "acréscimo de dados", text: "texto",
                                                         changes: { conducts: [ "9", "1" ] }
    expect(response).to have_http_status(:created)
    expect(body["changes"]["conducts"]).to eq(%w[9 1])
    expect(ConsultationAddendum.sole.item_changes["conducts"]).to eq([ 9, 1 ])
  end

  it "finaliza com o desfecho; requisitos 422; erros do close passam" do
    id = start!["id"]
    json_patch "/attendance/consultations/#{id}", draft_body(conducts: [])
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "discharged" }
    expect(status_and_error).to eq([ 422, "no_conduct" ])
    json_patch "/attendance/consultations/#{id}", "conducts" => [ 1 ]
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "referred" }
    expect(status_and_error).to eq([ 422, "referral_required" ])
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "return" }
    expect(response).to have_http_status(:ok)
    expect(body.values_at("status", "conducts")).to eq([ "finalized", [ "1" ] ])
    expect(attendance.reload.outcome).to eq("return")
  end

  it "leitura: rascunho só do autor; finalizada pela autora, em contexto ou com abertura; trilha" do
    id = start!["id"]
    nurse = doctor!(unit, cbo: "223505")
    sign_in_as(nurse)
    get "/attendance/consultations/#{id}"
    expect(status_and_error).to eq([ 403, "not_author" ])
    sign_in_as(doctor)
    json_patch "/attendance/consultations/#{id}", draft_body
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "discharged" }
    sign_in_as(nurse)
    get "/attendance/consultations/#{id}"
    expect(status_and_error).to eq([ 403, "out_of_context" ])
    patient_id = Consultation.find(id).patient_id
    now = Time.current
    ClinicalRecordOpening.create!(patient_id: patient_id, user: nurse, reason_code: "case_review", created_at: now, expires_at: now + 30.minutes)
    get "/attendance/consultations/#{id}"
    expect(response).to have_http_status(:ok)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).pluck(:payload).last)
      .to eq("patient_id" => patient_id, "user_id" => nurse.id, "access" => "justified", "reason_code" => "case_review")
    sign_in_as(doctor)
    get "/attendance/consultations/#{id}"
    expect(response).to have_http_status(:ok)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).pluck(:payload).last)
      .to eq("patient_id" => patient_id, "user_id" => doctor.id, "access" => "author", "reason_code" => nil)
  end

  # Decisão do usuário (2026-10-09): outro profissional só visualiza (contexto
  # ou abertura); impresso e adendo são só da autora, mesmo com contexto ou abertura.
  it "outro profissional em contexto ou com abertura: lê; impresso e adendo 403 not_author" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    walk_in_attendance!(unit, citizen: citizen.reload)
    nurse = doctor!(unit, cbo: "223505")
    sign_in_as(nurse)
    get "/attendance/consultations/#{consultation.id}"
    expect(response).to have_http_status(:ok)
    expect(DomainEvent.where(name: "clinical_record.viewed").order(:occurred_at, :created_at).pluck(:payload).last).to include("access" => "in_context")
    now = Time.current
    opening = ClinicalRecordOpening.create!(patient: consultation.patient, user: nurse, reason_code: "case_review",
                                            created_at: now, expires_at: now + 30.minutes)
    get "/attendance/consultations/#{consultation.id}/print"
    expect(status_and_error).to eq([ 403, "not_author" ])
    json_post "/attendance/consultations/#{consultation.id}/addenda", reason: "acréscimo de dados", text: "texto",
                                                                      opening_id: opening.id
    expect(status_and_error).to eq([ 403, "not_author" ])
    json_post "/attendance/consultations/#{consultation.id}/addenda", reason: "curto", text: "texto"
    expect(status_and_error).to eq([ 403, "not_author" ])
    expect(ConsultationAddendum.count).to eq(0)
  end

  it "adendo (201) da autora; opening_id dela aceito e ignorado; de terceiro 403; em rascunho 409" do
    id = start!["id"]
    json_post "/attendance/consultations/#{id}/addenda", reason: "acréscimo de dados", text: "texto"
    expect(status_and_error).to eq([ 409, "not_finalized" ])
    json_patch "/attendance/consultations/#{id}", draft_body
    json_post "/attendance/consultations/#{id}/finalize", outcome: { outcome: "discharged" }
    json_post "/attendance/consultations/#{id}/addenda", reason: "acréscimo de dados", text: "texto",
                                                         changes: { conducts: [ 1, 9 ] }
    expect(response).to have_http_status(:created)
    expect(body.keys).to match_array(%w[id author_name created_at reason text changes signature])
    json_post "/attendance/consultations/#{id}/addenda", reason: "curto", text: "texto"
    expect(status_and_error).to eq([ 422, "invalid_reason" ])
    now = Time.current
    mine = ClinicalRecordOpening.create!(patient_id: Consultation.find(id).patient_id, user: doctor, reason_code: "case_review",
                                         created_at: now, expires_at: now + 30.minutes)
    json_post "/attendance/consultations/#{id}/addenda", reason: "acréscimo de dados", text: "texto", opening_id: mine.id
    expect(response).to have_http_status(:created)
    expect(ConsultationAddendum.where.not(opening_id: nil)).to be_empty
    sign_in_as(doctor!(unit, cbo: "223505"))
    json_post "/attendance/consultations/#{id}/addenda", reason: "acréscimo de dados", text: "texto"
    expect(status_and_error).to eq([ 403, "not_author" ])
  end

  # Contrato §9 D10 + physicians_only: qualquer vínculo ativo permitido do usuário.
  it "cid10_allowed_for_cbo: médico sim, enfermeira não, quem tem os dois vínculos sim" do
    nurse = doctor!(unit, cbo: "223505")
    sign_in_as(nurse)
    get "/attendance/consultation_options"
    expect(body["cid10_allowed_for_cbo"]).to be(false)
    # O vínculo de enfermagem é o mais antigo: o primeiro que Authorization escolhe.
    both = travel_to(1.day.ago) { doctor!(unit, cbo: "223505") }
    link_professional!(both, create_unit("UBS Norte"), cbo: "225125")
    sign_in_as(both)
    get "/attendance/consultation_options"
    expect(body["cid10_allowed_for_cbo"]).to be(true)
  end

  # Task 22 (decisão do usuário 2026-10-09): o admin municipal lê as opções
  # (rótulos da tela "Consultas por profissional"); as demais rotas seguem
  # exigindo health_professional.
  describe "opções para o admin municipal" do
    let(:admin) { staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin") }

    it "admin sem health_professional: 200, cid10 false, códigos string" do
      sign_in_as(admin)
      get "/attendance/consultation_options"
      expect(response).to have_http_status(:ok)
      expect(body["cid10_allowed_for_cbo"]).to be(false)
      expect(body["care_types"].map { |t| t["code"] }).to eq(%w[1 2 5 6])
      expect(body["conducts"].map { |c| c["code"] }).to all(be_a(String))
      expect(body["conducts"]).not_to be_empty
    end

    it "recepção: 403 missing_role" do
      sign_in_as(verifier!)
      get "/attendance/consultation_options"
      expect(status_and_error).to eq([ 403, "missing_role" ])
    end

    it "interruptor desligado: 403 feature_disabled para o admin" do
      clinical_city!(enabled: false)
      sign_in_as(admin)
      get "/attendance/consultation_options"
      expect([ response.status, body["error"] ]).to eq([ 403, "feature_disabled" ])
    end

    it "admin sem health_professional segue com 403 missing_role nas outras rotas" do
      sign_in_as(admin)
      get "/attendance/consultations/mine"
      expect(status_and_error).to eq([ 403, "missing_role" ])
    end
  end

  it "interruptor desligado: 403 feature_disabled em toda rota da consulta (ClinicalRecordGate)" do
    id = start!["id"]
    clinical_city!(enabled: false)
    [ [ :get, "/attendance/consultation_options" ], [ :get, "/attendance/consultations/#{id}" ],
      [ :patch, "/attendance/consultations/#{id}" ], [ :post, "/attendance/consultations/#{id}/finalize" ],
      [ :post, "/attendance/consultations/#{id}/addenda" ], [ :get, "/attendance/attendances/#{attendance.id}/record" ] ]
      .each do |verb, path|
      send(verb, path, params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" })
      expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "clinical_record" ]), "#{verb} #{path}"
    end
  end

  it "chave desconhecida no autosave é ignorada" do
    id = start!["id"]
    json_patch "/attendance/consultations/#{id}", "plan" => "retorno", "bogus" => { "a" => 1 }, "status" => "finalized"
    expect(response).to have_http_status(:ok)
    expect(body.values_at("plan", "status")).to eq([ "retorno", "draft" ])
  end

  it "desfecho do atendimento com consulta em rascunho → 409 consultation_in_progress" do
    start!
    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "discharged"
    expect(status_and_error).to eq([ 409, "consultation_in_progress" ])
    expect(attendance.reload.status).to eq("in_care")
  end

  it "enfermeira finalizando só com CID-10 avaliado → 422 ciap2_required_for_cbo" do
    finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen,
                            evaluated_problems: [ { "terminology" => "cid10", "code" => "E119", "action" => "add" } ])
    nurse = doctor!(unit, cbo: "223505")
    nursing = started_consultation!(unit: unit, doctor: nurse, citizen: citizen.reload)
    cid10 = PatientProblem.find_by!(code: "E119")
    sign_in_as(nurse)
    json_patch "/attendance/consultations/#{nursing.id}",
               draft_body(evaluated_problems: [ { "problem_id" => cid10.id, "action" => "evaluate" } ])
    expect(response).to have_http_status(:ok)
    json_post "/attendance/consultations/#{nursing.id}/finalize", outcome: { outcome: "discharged" }
    expect(status_and_error).to eq([ 422, "ciap2_required_for_cbo" ])
    expect(nursing.reload.status).to eq("draft")
  end
end

# Módulo 26a, Task 5 (ADR 0044; contrato §13 G4, G12 #3–#5; plano do api,
# Desvio 2): regulation_not_sent na finalização e no adendo (só com o
# interruptor utilizável) e o "encaminhado" sem unidade pela regulação.
RSpec.describe "Consulta — pedidos de regulação na finalização e no adendo", type: :request do
  let!(:city) { regulation_city! }
  let(:unit) { create_unit("UBS Regulação na consulta") }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { regulation_patient!(exam_seq!).last }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  def draft!(consultation)
    CareRegulation::SaveDraft.call(consultation: consultation, attrs: RegulationHelpers::REGULATION_DEFAULTS.dup, by: doctor)
                             .payload.fetch(:request)
  end

  def prepared_consultation!
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    Consultations::SaveDraft.call(consultation: consultation, params: draft_body, by: doctor)
    consultation
  end

  it "interruptor ligado: finalize devolve regulation_not_sent vazio quando tudo foi" do
    consultation = prepared_consultation!
    request = draft!(consultation)
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "referred" }
    expect(response).to have_http_status(:ok)
    expect(body).to include("status" => "finalized", "regulation_not_sent" => [])
    expect(request.reload.status).to eq("pending")
  end

  it "interruptor desligado: finalize sem a chave regulation_not_sent, e o rascunho fica" do
    consultation = prepared_consultation!
    request = draft!(consultation)
    regulation_city!(enabled: false)
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "discharged" }
    expect(response).to have_http_status(:ok)
    expect(body).not_to have_key("regulation_not_sent")
    expect(request.reload.status).to eq("draft")
  end

  it "finalize 'encaminhado' sem unidade e sem pedido → 422 regulation_request_required, consulta em rascunho" do
    consultation = prepared_consultation!
    sign_in_as(doctor)
    json_post "/attendance/consultations/#{consultation.id}/finalize", outcome: { outcome: "referred", referral_note: "Cardiologia" }
    expect(status_and_error).to eq([ 422, "regulation_request_required" ])
    expect(consultation.reload.status).to eq("draft")
  end

  it "adendo (201) devolve regulation_not_sent com o rascunho que não vale mais, sem dado pessoal" do
    admin = staff_with("adm-#{SecureRandom.hex(2)}@cidade.gov.br", "municipal_admin")
    nurse = screener!(unit, cbo: "223505")
    consultation = finalized_consultation!(unit: unit, doctor: nurse, citizen: citizen)
    CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225120", by: admin)
    request = CareRegulation::SaveDraft.call(consultation: consultation, by: nurse,
                                             attrs: RegulationHelpers::REGULATION_DEFAULTS.merge("cid10" => nil, "ciap2" => "K86"))
                                       .payload.fetch(:request)
    CareRegulation::NurseItems.remove(target_type: "specialty", target_code: "225120", by: admin)
    sign_in_as(nurse)
    json_post "/attendance/consultations/#{consultation.id}/addenda", reason: "Pedido de cardiologia esquecido",
                                                                      text: "Acrescento encaminhamento à cardiologia."
    expect(response).to have_http_status(:created)
    expect(body["regulation_not_sent"]).to eq([ { "index" => 0, "id" => request.id, "error" => "cbo_not_allowed", "path" => "target_code" } ])
    expect(request.reload.status).to eq("draft")
  end

  it "close do atendimento: 'encaminhado' só com nota → 422 regulation_request_required ligado; desligado → 200 como hoje" do
    attendance = consulting_attendance!(unit, citizen: citizen, doctor: doctor)
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "referred", referral_note: "Cardiologia"
    expect(status_and_error).to eq([ 422, "regulation_request_required" ])
    expect(attendance.reload.status).to eq("in_care")
    regulation_city!(enabled: false)
    json_post "/attendance/attendances/#{attendance.id}/close", outcome: "referred", referral_note: "Cardiologia"
    expect(response).to have_http_status(:ok)
    expect(attendance.reload.outcome).to eq("referred")
  end
end
