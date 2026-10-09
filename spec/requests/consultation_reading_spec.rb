require "rails_helper"

# Decisão do usuário (2026-10-09; contrato §9): a autora lê e imprime a
# consulta FINALIZADA a qualquer momento, sem atendimento aberto e sem
# abertura; "minhas consultas"; leitura administrativa do municipal_admin
# (step-up, conteúdo completo, só leitura), que entra no relatório.
RSpec.describe "Leitura da consulta finalizada", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:admin) do
    staff_with("adm-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]
  def viewed = DomainEvent.where(name: "clinical_record.viewed")
  def step_up!(user) = sign_in_as(user).update!(mfa_verified_at: Time.current)
  def json_patch(path, params) = patch(path, params: params.to_json, headers: { "CONTENT_TYPE" => "application/json" })

  it "a autora finaliza (o atendimento fecha) e lê e imprime quantas vezes quiser, com trilha author" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    expect(consultation.attendance.reload.status).to eq("closed")
    sign_in_as(doctor)
    2.times do
      get "/attendance/consultations/#{consultation.id}"
      expect([ response.status, body["id"], body["subjective"] ]).to eq([ 200, consultation.id, consultation.subjective ])
      get "/attendance/consultations/#{consultation.id}/print"
      expect([ response.status, response.media_type ]).to eq([ 200, "application/pdf" ])
    end
    author_read = { "patient_id" => consultation.patient_id, "user_id" => doctor.id, "access" => "author", "reason_code" => nil }
    expect(viewed.pluck(:payload)).to eq([ author_read ] * 4)
    expect(ClinicalRecordOpening.count).to eq(0)
  end

  it "a autora que perde o papel health_professional perde o acesso" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    doctor.memberships.update_all(revoked_at: Time.current)
    sign_in_as(doctor)
    get "/attendance/consultations/#{consultation.id}"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    get "/attendance/consultations/mine"
    expect(status_and_error).to eq([ 403, "missing_role" ])
  end

  it "minhas consultas: só finalizadas, só as dela, mais novas primeiro, período no fuso da cidade, sem trilha" do
    old = travel_to(2.days.ago) do
      finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1), exam_requests: [])
    end
    recent = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2, social_name: "Mariana"))
    started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(3))
    finalized_consultation!(unit: unit, doctor: doctor!(unit), citizen: verified_citizen!(4))
    sign_in_as(doctor)
    expect { get "/attendance/consultations/mine" }.not_to(change { viewed.count })
    expect(body["consultations"].map { |c| c["id"] }).to eq([ recent.id, old.id ])
    expect(body["consultations"].first).to eq(
      "id" => recent.id, "finalized_at" => recent.finalized_at.iso8601,
      "patient" => { "id" => recent.patient_id, "display_name" => "Mariana" },
      "care_type" => "5", "care_type_label" => Ledi::ConsultationMapping.care_type_label(5),
      "health_unit" => { "id" => unit.id, "name" => unit.name }
    )
    get "/attendance/consultations/mine", params: { from: Time.zone.today.iso8601 }
    expect(body["consultations"].map { |c| c["id"] }).to eq([ recent.id ])
    get "/attendance/consultations/mine", params: { to: (Time.zone.today - 1).iso8601 }
    expect(body["consultations"].map { |c| c["id"] }).to eq([ old.id ])
    [ { from: "ontem" }, { to: "2026-02-30" } ].each do |params|
      get "/attendance/consultations/mine", params: params
      expect(status_and_error).to eq([ 422, "invalid_period" ]), params.inspect
    end
    stub_const("Consultation::LIST_LIMIT", 1)
    get "/attendance/consultations/mine"
    expect(body["consultations"].map { |c| c["id"] }).to eq([ recent.id ])
  end

  it "minhas consultas: recepção 403 missing_role; interruptor desligado 403 feature_disabled" do
    sign_in_as(reception!)
    get "/attendance/consultations/mine"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    clinical_city!(enabled: false)
    sign_in_as(doctor)
    get "/attendance/consultations/mine"
    expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "clinical_record" ])
  end

  it "leitura administrativa: step-up nas duas rotas; conteúdo completo; rascunho 404; trilha administrative" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1, social_name: "Mariana"))
    Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "acréscimo de dados", text: "texto do adendo")
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(2))
    list = "/clinical_record/professionals/#{doctor.id}/consultations"
    read = "/clinical_record/consultations/#{consultation.id}"

    sign_in_as(admin)
    [ list, read ].each do |path|
      get path
      expect(status_and_error).to eq([ 401, "mfa_required" ]), path
    end
    sign_in_as(admin).update!(mfa_verified_at: 6.minutes.ago)
    get read
    expect(status_and_error).to eq([ 401, "mfa_required" ])
    expect(viewed.count).to eq(0)

    step_up!(admin)
    expect { get list }.not_to(change { viewed.count })
    expect(body["professional"]).to eq("id" => doctor.id, "name" => doctor.professional.professional_name)
    expect(body["consultations"].sole).to include("id" => consultation.id,
                                                  "patient" => { "id" => consultation.patient_id, "display_name" => "Mariana" })
    get read
    expect(response).to have_http_status(:ok)
    expect(body).to eq(JSON.parse(Consultations::Json.consultation(consultation.reload).to_json))
    expect(body.values_at("subjective", "plan")).to eq(consultation.reload.then { |c| [ c.subjective, c.plan ] })
    expect(body["addenda"].sole["text"]).to eq("texto do adendo")
    expect(viewed.pluck(:payload).last)
      .to eq("patient_id" => consultation.patient_id, "user_id" => admin.id, "access" => "administrative",
             "reason_code" => nil, "consultation_id" => consultation.id)

    { "/clinical_record/consultations/#{draft.id}" => "rascunho", "/clinical_record/consultations/#{SecureRandom.uuid}" => "inexistente",
      "/clinical_record/consultations/nao-uuid" => "id inválido",
      "/clinical_record/professionals/#{SecureRandom.uuid}/consultations" => "profissional inexistente" }.each do |path, label|
      expect { get path }.not_to(change { viewed.count })
      expect(status_and_error).to eq([ 404, "not_found" ]), label
    end
    expect(response.body).not_to include(draft.id)
    get list, params: { from: "ontem" }
    expect(status_and_error).to eq([ 422, "invalid_period" ])
    get list, params: { to: (Time.zone.today - 1).iso8601 }
    expect(body["consultations"]).to eq([])

    # Só leitura: sem impresso, sem adendo, sem edição.
    get "/attendance/consultations/#{consultation.id}/print"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    json_post "/attendance/consultations/#{consultation.id}/addenda", reason: "acréscimo de dados", text: "texto"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    json_patch "/attendance/consultations/#{draft.id}", "plan" => "x"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    expect(ConsultationAddendum.count).to eq(1)
  end

  it "rotas administrativas: profissional não admin 403 missing_role; interruptor desligado 403 feature_disabled" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    paths = [ "/clinical_record/professionals/#{doctor.id}/consultations", "/clinical_record/consultations/#{consultation.id}" ]
    doctor.tap { |u| Mfa::Enroll.call(u) }.update!(otp_enabled: true)
    step_up!(doctor)
    paths.each do |path|
      get path
      expect(status_and_error).to eq([ 403, "missing_role" ]), path
    end
    clinical_city!(enabled: false)
    step_up!(admin)
    paths.each do |path|
      get path
      expect([ response.status, body["error"], body["feature"] ]).to eq([ 403, "feature_disabled", "clinical_record" ]), path
    end
  end

  it "relatório: aberturas (justified_opening) e leituras administrativas (administrative_read); a da autora não entra" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    patient = consultation.patient
    nurse = doctor!(unit, cbo: "223505")
    opening = travel_to(1.minute.ago) do
      ClinicalRecordOpening.create!(patient: patient, user: nurse, reason_code: "case_review", created_at: Time.current,
                                    expires_at: Time.current + 30.minutes)
    end
    sign_in_as(doctor)
    get "/attendance/consultations/#{consultation.id}"
    step_up!(admin)
    get "/clinical_record/consultations/#{consultation.id}"
    event = viewed.where("payload->>'access' = ?", "administrative").sole

    get "/clinical_record/openings"
    administrative = { "kind" => "administrative_read", "id" => event.id, "user_name" => admin.email_address,
                       "cpf_masked" => patient.cpf_masked, "reason_code" => nil, "consultation_id" => consultation.id,
                       "created_at" => event.occurred_at.iso8601, "expires_at" => nil }
    justified = { "kind" => "justified_opening", "id" => opening.id, "user_name" => nurse.professional.professional_name,
                  "cpf_masked" => patient.cpf_masked, "reason_code" => "case_review", "consultation_id" => nil,
                  "created_at" => opening.created_at.iso8601, "expires_at" => opening.expires_at.iso8601 }
    expect(body["items"]).to eq([ administrative, justified ])
    get "/clinical_record/openings", params: { user_id: admin.id }
    expect(body["items"]).to eq([ administrative ])
    get "/clinical_record/openings", params: { user_id: nurse.id }
    expect(body["items"]).to eq([ justified ])
    get "/clinical_record/openings", params: { user_id: doctor.id }
    expect(body["items"]).to eq([])
    get "/clinical_record/openings", params: { from: Time.zone.today.iso8601, to: Time.zone.today.iso8601 }
    expect(body["items"].size).to eq(2)
    get "/clinical_record/openings", params: { to: (Time.zone.today - 1).iso8601 }
    expect(body["items"]).to eq([])
    stub_const("ClinicalRecordOpeningsController::REPORT_LIMIT", 1)
    get "/clinical_record/openings"
    expect(body["items"]).to eq([ administrative ])
  end
end
