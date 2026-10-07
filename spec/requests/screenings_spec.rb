require "rails_helper"

# Contratos §3: escuta inicial em /attendance.
RSpec.describe "Escuta inicial", type: :request do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1)) }
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]

  def start!
    sign_in_as(nurse)
    json_post "/attendance/attendances/#{attendance.id}/screening"
    body
  end

  it "inicia (201 com a forma do contrato); de novo 409; recepção 403; outra unidade 403; CBO fora 403" do
    expect(start!.keys).to match_array(%w[id attendance_id status started_at completed_at destination current_revision revisions_count])
    expect(response).to have_http_status(:created)
    expect(body.values_at("status", "current_revision", "revisions_count")).to eq([ "in_progress", nil, 0 ])
    json_post "/attendance/attendances/#{attendance.id}/screening"
    expect(status_and_error).to eq([ 409, "already_screening" ])

    other = walk_in_attendance!(unit, citizen: screening_citizen!(2))
    sign_in_as(reception!)
    json_post "/attendance/attendances/#{other.id}/screening"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    sign_in_as(screener!(create_unit("UBS Outra")))
    json_post "/attendance/attendances/#{other.id}/screening"
    expect(status_and_error).to eq([ 403, "missing_link" ])
    sign_in_as(screener!(unit, cbo: "322405"))
    json_post "/attendance/attendances/#{other.id}/screening"
    expect(status_and_error).to eq([ 403, "cbo_not_allowed" ])
    json_post "/attendance/attendances/#{SecureRandom.uuid}/screening"
    expect(status_and_error).to eq([ 404, "not_found" ])
  end

  it "conclui com destino; erros de entrada 422 com field; escuta já concluída 409" do
    id = start!["id"]
    json_post "/attendance/screenings/#{id}/complete", revision_params(vitals: { "spo2" => 30 }).merge(destination: "same_day")
    expect([ response.status, body["error"], body["field"] ]).to eq([ 422, "implausible_vital", "spo2" ])
    json_post "/attendance/screenings/#{id}/complete", revision_params(vitals: "lixo").merge(destination: "same_day")
    expect([ response.status, body["error"], body["field"] ]).to eq([ 422, "implausible_vital", "vitals" ])
    json_post "/attendance/screenings/#{id}/complete", revision_params.merge(destination: "amanhã")
    expect(status_and_error).to eq([ 422, "invalid_destination" ])
    json_post "/attendance/screenings/#{id}/complete", revision_params.merge(destination: "oriented")
    expect(status_and_error).to eq([ 422, "orientation_required" ])

    json_post "/attendance/screenings/#{id}/complete",
              revision_params(complaint_note: "dor de cabeça").merge(destination: "oriented", orientation_note: "repouso")
    expect(response).to have_http_status(:ok)
    expect(body.values_at("status", "destination", "orientation_note")).to eq([ "completed", "oriented", "repouso" ])
    expect(body.dig("current_revision", "complaint_note")).to eq("dor de cabeça")
    json_post "/attendance/screenings/#{id}/complete", revision_params.merge(destination: "same_day")
    expect(status_and_error).to eq([ 409, "not_in_progress" ])
  end

  it "schedule pelo corpo do contrato abre o pedido" do
    id = start!["id"]
    json_post "/attendance/screenings/#{id}/complete",
              revision_params(final_color: "green").merge(destination: "schedule",
                                                          schedule: { appointment_type_key: appointment_type!.key, priority: "routine" })
    expect(response).to have_http_status(:ok)
    expect(AppointmentRequest.find(body["appointment_request_id"])).to have_attributes(kind: "screening", due_on: Time.zone.today + 15)
  end

  it "reavalia (200) só same_day e aguardando; abandona (200) só em curso" do
    id = start!["id"]
    json_post "/attendance/screenings/#{id}/reassess", revision_params
    expect(status_and_error).to eq([ 409, "not_reassessable" ])
    json_post "/attendance/screenings/#{id}/complete", revision_params.merge(destination: "same_day")
    json_post "/attendance/screenings/#{id}/reassess", revision_params(final_color: "yellow")
    expect([ response.status, body["revisions_count"], body.dig("current_revision", "final_color") ]).to eq([ 200, 2, "yellow" ])
    json_post "/attendance/screenings/#{id}/abandon"
    expect(status_and_error).to eq([ 409, "not_in_progress" ])
  end

  it "leitura: profissional da unidade lê com as revisões e deixa trilha; recepção e outra unidade 403" do
    id = start!["id"]
    json_post "/attendance/screenings/#{id}/complete", revision_params.merge(destination: "same_day")
    doctor = screener!(unit, cbo: "225125")
    sign_in_as(doctor)
    get "/attendance/screenings/#{id}"
    expect(response).to have_http_status(:ok)
    expect(body["revisions"].size).to eq(1)
    expect(DomainEvent.where(name: "screening.viewed").pluck(:payload)).to eq([ { "screening_id" => id, "user_id" => doctor.id } ])
    sign_in_as(reception!)
    get "/attendance/screenings/#{id}"
    expect(status_and_error).to eq([ 403, "missing_role" ])
    sign_in_as(screener!(create_unit("UBS Outra"), cbo: "225125"))
    get "/attendance/screenings/#{id}"
    expect(status_and_error).to eq([ 403, "missing_link" ])
  end

  it "sugestão sem gravar: cor, regras, alertas e IMC; atendimento desconhecido 404; outra unidade 403; sinais lixo 422" do
    acolhimento!
    sign_in_as(nurse)
    json_post "/attendance/screenings/suggest", ciap2_code: "K86", attendance_id: attendance.id,
                                                vitals: { systolic: 185, diastolic: 110, weight_kg: "80", height_cm: 175 }
    expect(body).to eq("suggested_color" => "red",
                       "matched_rules" => [ { "index" => 0, "text" => "pressão sistólica ≥ 180 ou saturação < 90" } ],
                       "alerts" => %w[systolic_high diastolic_high], "bmi" => 26.1)
    expect(ScreeningRevision.count).to eq(0)
    json_post "/attendance/screenings/suggest", ciap2_code: "K86", attendance_id: SecureRandom.uuid, vitals: {}
    expect(status_and_error).to eq([ 404, "not_found" ])
    json_post "/attendance/screenings/suggest", ciap2_code: "K86", attendance_id: attendance.id, vitals: { spo2: "x" }
    expect(status_and_error).to eq([ 422, "implausible_vital" ])
    json_post "/attendance/screenings/suggest", ciap2_code: "Z99", attendance_id: attendance.id, vitals: {}
    expect(status_and_error).to eq([ 422, "invalid_ciap2" ])
    sign_in_as(screener!(create_unit("UBS Outra")))
    json_post "/attendance/screenings/suggest", ciap2_code: "K86", attendance_id: attendance.id, vitals: {}
    expect(status_and_error).to eq([ 403, "missing_link" ])
  end

  it "busca de CIAP-2 por nome ou código, só para profissionais; sem release ativa 503" do
    sign_in_as(nurse)
    json_post "/attendance/ciap2/search", q: "tosse"
    expect(body).to eq("items" => [ { "code" => "R05", "label" => "Tosse" } ])
    json_post "/attendance/ciap2/search", q: [ "x" ]
    expect(body).to eq("items" => [])
    allow(Screenings::Ciap2).to receive(:release).and_return(nil)
    json_post "/attendance/ciap2/search", q: "tosse"
    expect(status_and_error).to eq([ 503, "terminology_unavailable" ])
    sign_in_as(reception!)
    json_post "/attendance/ciap2/search", q: "tosse"
    expect(status_and_error).to eq([ 403, "missing_role" ])
  end
end
