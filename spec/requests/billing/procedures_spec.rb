require "rails_helper"

# Contrato §3 com B1, B2, B5, B8 e B12 do dashboard (F-22.2, F-22.4): grava
# pelo atendimento e pela consulta (paciente derivado), avulso do
# profissional na própria unidade e lançamento do faturista (quem fez e CBO
# opcional, só do faturista); sempre 201 com a crítica nos campos; lista
# com envelope e filtros, inclusive por atendimento; cancelamento: o
# profissional os próprios, o faturista qualquer um. Outro escopo por id →
# 404; papel/escopo alheio → 403.
RSpec.describe "Faturamento — procedimentos", type: :request do
  before { billing_city! }

  let(:unit) { upa! }
  let(:doctor) { doctor!(unit) }
  let(:clerk) { billing_clerk! }
  let(:pair) { exam_patient!(exam_seq!) }
  let(:patient) { pair.first }
  let(:today) { Time.zone.today.iso8601 }

  def body(**over)
    { patient_id: patient.id, establishment: { type: "health_unit", id: unit.id }, performed_on: today, sigtap_code: "0301060029",
      quantity: 1, cid10: "I10" }.merge(over)
  end

  def post_procedure(user, **over)
    sign_in_as(user)
    json_post "/billing/procedures", body(**over)
  end

  it "desligado: 403 feature_disabled" do
    Platform::Features.set!(city: Current.city, key: "procedure_billing", enabled: false, maintainer: ledi_maintainer!)
    post_procedure(doctor)
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "procedure_billing")
  end

  it "avulso do profissional na própria unidade: 201 na forma do contrato" do
    post_procedure(doctor)
    expect(response).to have_http_status(:created)
    expect(json_body.keys).to match_array(%w[id patient establishment professional performed_on sigtap_code label sigtap_competence quantity
                                             cid10 character source source_ref instrument billable blocking_reasons status cancel_reason
                                             billing_competence late sigtap_fallback])
    expect(json_body).to include("patient" => { "id" => patient.id, "display_name" => "Maria Aparecida da Silva" },
                                 "establishment" => { "type" => "health_unit", "id" => unit.id, "cnes" => unit.cnes, "name" => unit.name },
                                 "performed_on" => today, "sigtap_code" => "0301060029", "quantity" => 1, "cid10" => "I10",
                                 "character" => "elective", "source" => "manual", "source_ref" => nil, "instrument" => "bpa_i",
                                 "billable" => true, "blocking_reasons" => [], "status" => "recorded", "late" => false,
                                 "label" => "ATENDIMENTO DE URGENCIA C/ OBSERVACAO ATE 24 HORAS EM ATENCAO ESPECIALIZADA")
    expect(json_body["professional"]).to include("user_id" => doctor.id, "cbo_code" => "225125")
  end

  it "não faturável também é 201, com o motivo" do
    post_procedure(doctor, cid10: nil)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("billable" => false, "blocking_reasons" => %w[cid_required])
  end

  it "profissional sem vínculo na unidade e recepção: 403; profissional mandando quem fez: 403" do
    other = doctor!(create_unit("UBS #{SecureRandom.hex(2)}"))
    post_procedure(other)
    expect(response).to have_http_status(:forbidden)
    post_procedure(verifier!)
    expect(response).to have_http_status(:forbidden)
    post_procedure(doctor, professional_user_id: doctor.id)
    expect(response).to have_http_status(:forbidden)
    expect(PerformedProcedure.count).to eq(0)
  end

  it "lançamento do faturista: quem fez com vínculo no estabelecimento; CBO opcional, entre os do vínculo" do
    post_procedure(clerk)
    expect(json_body).to eq("error" => "invalid_professional")
    post_procedure(clerk, professional_user_id: doctor!(create_unit("UPA #{SecureRandom.hex(2)}", kind: "upa")).id)
    expect(json_body).to eq("error" => "invalid_professional")
    post_procedure(clerk, professional_user_id: doctor.id, cbo_code: "223505")
    expect(json_body).to eq("error" => "invalid_professional")
    post_procedure(clerk, professional_user_id: doctor.id, cbo_code: "225125")
    expect(response).to have_http_status(:created)
    expect(PerformedProcedure.find(json_body["id"])).to have_attributes(professional_user_id: doctor.id, recorded_by_user_id: clerk.id,
                                                                       source: "manual", cbo_code: "225125")
  end

  it "lançamento do faturista no laboratório: o liberador do laboratório" do
    lab = lab_provider!
    releaser = lab_releaser!(lab)
    post_procedure(clerk, establishment: { type: "lab_provider", id: lab.id }, professional_user_id: releaser.id, sigtap_code: "0202010473",
                          cid10: nil)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("establishment" => include("type" => "lab_provider"), "blocking_reasons" => %w[missing_professional_cbo])
  end

  it "estabelecimento inválido 422; paciente inexistente 404; recusa de entrada 422" do
    post_procedure(clerk, professional_user_id: doctor.id, establishment: { type: "health_unit", id: SecureRandom.uuid })
    expect(json_body).to eq("error" => "invalid_establishment")
    post_procedure(clerk, professional_user_id: doctor.id, establishment: { type: "lab_provider", id: exam_provider!(name: "Particular").id })
    expect(json_body).to eq("error" => "invalid_establishment")
    post_procedure(clerk, professional_user_id: doctor.id, establishment: "x")
    expect(json_body).to eq("error" => "invalid_establishment")
    post_procedure(doctor, patient_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    post_procedure(doctor, quantity: 0)
    expect(json_body).to eq("error" => "invalid_quantity")
  end

  it "pelo atendimento (B1): paciente derivado; patient_id que não bate 422; atendimento inexistente 404" do
    attendance = walk_in_attendance!(unit, citizen: pair.last)
    post_procedure(doctor, patient_id: nil, attendance_id: attendance.id)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("patient" => include("id" => patient.id), "source" => "attendance",
                                 "source_ref" => { "type" => "attendance", "id" => attendance.id })
    post_procedure(doctor, patient_id: billing_patient!.id, attendance_id: attendance.id)
    expect(json_body).to eq("error" => "invalid_patient")
    post_procedure(doctor, attendance_id: attendance.id, establishment: { type: "health_unit", id: create_unit("UBS #{SecureRandom.hex(2)}").id })
    expect(json_body).to eq("error" => "invalid_establishment")
    post_procedure(doctor, attendance_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
  end

  it "pelo atendimento de par ainda sem paciente: o api resolve o paciente do par validado" do
    citizen = verified_citizen!(exam_seq!, age: 50)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    post_procedure(doctor, patient_id: nil, attendance_id: attendance.id)
    expect(response).to have_http_status(:created)
    expect(json_body["patient"]["id"]).to eq(citizen.reload.patient_id)
  end

  it "pelo atendimento de par não verificado: 409 citizen_not_verified (E7)" do
    citizen = verified_citizen!(exam_seq!, age: 50)
    attendance = walk_in_attendance!(unit, citizen: citizen)
    patient
    citizen.update_columns(patient_id: nil)
    allow(Patients::Resolve).to receive(:call).and_return(Result.fail(:citizen_not_verified))
    post_procedure(doctor, patient_id: nil, attendance_id: attendance.id)
    expect(response).to have_http_status(:conflict)
    expect(json_body).to eq("error" => "citizen_not_verified")
  end

  it "pela consulta: source consultation, CBO da consulta; outro profissional 403" do
    consultation = started_consultation!(unit: unit, doctor: doctor, citizen: pair.last)
    post_procedure(doctor, patient_id: nil, consultation_id: consultation.id, establishment: nil)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("source" => "consultation", "source_ref" => { "type" => "consultation", "id" => consultation.id })
    expect(json_body["professional"]["cbo_code"]).to eq(consultation.cbo_code)
    post_procedure(doctor!(unit), consultation_id: consultation.id, establishment: nil)
    expect(response).to have_http_status(:forbidden)
  end

  it "lista: faturista vê tudo com filtros e envelope; profissional os próprios do paciente ou os do atendimento (B2)" do
    ok = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    bad = recorded_procedure!(unit: unit, professional: doctor, patient: patient, cid10: nil)
    sign_in_as(clerk)
    get "/billing/procedures", params: { establishment_type: "health_unit", establishment_id: unit.id, competence: Time.zone.today.strftime("%Y%m"),
                                         billable: "false", reason: "cid_required" }
    expect(json_body["procedures"].map { |p| p["id"] }).to eq([ bad.id ])
    get "/billing/procedures", params: { limit: 1 }
    expect(json_body["procedures"].size).to eq(1)
    get "/billing/procedures", params: { limit: 1, before: json_body["next_before"] }
    expect(json_body["procedures"].map { |p| p["id"] }).to eq([ ok.id ])
    get "/billing/procedures", params: { reason: "whatever" }
    expect(json_body).to eq("error" => "invalid_filter")
    get "/billing/procedures", params: { before: "@@" }
    expect(json_body).to eq("error" => "invalid_cursor")
    sign_in_as(doctor)
    get "/billing/procedures"
    expect(response).to have_http_status(:forbidden)
    get "/billing/procedures", params: { patient_id: patient.id }
    expect(json_body["procedures"].size).to eq(2)
    sign_in_as(doctor!(unit))
    get "/billing/procedures", params: { patient_id: patient.id }
    expect(json_body["procedures"]).to eq([])
  end

  # §13 E19: a lista mostra nome de paciente; uma trilha de leitura por requisição com resultado, só ids.
  it "lista grava uma trilha por requisição com os ids da página; lista vazia não grava" do
    first = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    second = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    sign_in_as(clerk)
    expect { get "/billing/procedures" }.to change { DomainEvent.where(name: "billing_procedures.listed").count }.by(1)
    event = DomainEvent.where(name: "billing_procedures.listed").sole
    expect(event.payload.keys).to match_array(%w[user_id procedure_ids])
    expect(event.payload).to include("user_id" => clerk.id)
    expect(event.payload["procedure_ids"]).to eq([ second.id, first.id ])
    expect { get "/billing/procedures", params: { competence: "200001" } }.not_to(change { DomainEvent.where(name: "billing_procedures.listed").count })
    expect(json_body["procedures"]).to eq([])
  end

  it "lista por atendimento: quem tem vínculo na unidade vê todos os do atendimento; sem vínculo 403" do
    attendance = walk_in_attendance!(unit, citizen: pair.last)
    sign_in_as(doctor)
    json_post "/billing/procedures", body(patient_id: nil, attendance_id: attendance.id)
    sign_in_as(doctor!(unit))
    get "/billing/procedures", params: { attendance_id: attendance.id }
    expect(json_body["procedures"].map { |p| p["source"] }).to eq(%w[attendance])
    sign_in_as(doctor!(create_unit("UBS #{SecureRandom.hex(2)}")))
    get "/billing/procedures", params: { attendance_id: attendance.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "cancelar (B8, B12): o próprio profissional e o faturista; outro profissional 404; admin lê mas não cancela" do
    procedure = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    sign_in_as(doctor!(unit))
    json_post "/billing/procedures/#{procedure.id}/cancel", reason: "Lançado em duplicidade"
    expect(response).to have_http_status(:not_found)
    sign_in_as(lab_admin!)
    json_post "/billing/procedures/#{procedure.id}/cancel", reason: "Lançado em duplicidade"
    expect(response).to have_http_status(:forbidden)
    sign_in_as(doctor)
    json_post "/billing/procedures/#{procedure.id}/cancel", reason: "curto"
    expect(json_body).to eq("error" => "reason_required")
    json_post "/billing/procedures/#{procedure.id}/cancel", reason: "Lançado em duplicidade"
    expect(json_body).to include("status" => "cancelled", "cancel_reason" => "Lançado em duplicidade")
    json_post "/billing/procedures/#{procedure.id}/cancel", reason: "De novo, por engano"
    expect(response).to have_http_status(:conflict)
    other = recorded_procedure!(unit: unit, professional: doctor, patient: patient)
    sign_in_as(clerk)
    json_post "/billing/procedures/#{other.id}/cancel", reason: "Procedimento não realizado"
    expect(json_body["status"]).to eq("cancelled")
  end
end
