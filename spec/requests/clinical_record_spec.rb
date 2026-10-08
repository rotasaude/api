require "rails_helper"

# Contratos §3: prontuário em contexto, abertura justificada (step-up, 30
# min), leitura justificada, relatório (municipal_admin). A recepção nunca
# lê: 403 em toda rota do prontuário. Review Focus 5.
RSpec.describe "Prontuário", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  before { clinical_city!; ciap2_release!; cid10_release!; sigtap_release! }

  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:citizen) { verified_citizen!(1, social_name: "Mariana") }
  let(:nurse) do
    doctor!(unit, cbo: "223505").tap do |u|
      Mfa::Enroll.call(u)
      u.update!(otp_enabled: true)
    end
  end
  def body = JSON.parse(response.body)
  def status_and_error = [ response.status, body["error"] ]
  def step_up!(user) = sign_in_as(user).update!(mfa_verified_at: Time.current)

  it "em contexto: o prontuário do atendimento chamado, com a escuta do dia e trilha" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    attendance = consulting_attendance!(unit, citizen: citizen.reload, doctor: doctor)
    sign_in_as(doctor)
    get "/attendance/attendances/#{attendance.id}/record"
    expect(response).to have_http_status(:ok)
    expect(body.dig("patient", "display_name")).to eq("Mariana")
    expect(body["access"]).to eq("in_context")
    expect(body["consultations"].sole["id"]).to eq(consultation.id)
    expect(DomainEvent.where(name: "clinical_record.viewed").pluck(:payload).last)
      .to eq("patient_id" => consultation.patient_id, "user_id" => doctor.id, "access" => "in_context", "reason_code" => nil)
    sign_in_as(doctor!(unit, cbo: "225142"))
    get "/attendance/attendances/#{attendance.id}/record"
    expect(status_and_error).to eq([ 403, "out_of_context" ])
  end

  it "par não validado → 409; par validado sem paciente → id nulo e sem trilha de prontuário" do
    declared = consulting_attendance!(unit, citizen: screening_citizen!(5), doctor: doctor)
    sign_in_as(doctor)
    get "/attendance/attendances/#{declared.id}/record"
    expect(status_and_error).to eq([ 409, "citizen_not_verified" ])
    fresh = consulting_attendance!(unit, citizen: verified_citizen!(6), doctor: doctor)
    get "/attendance/attendances/#{fresh.id}/record"
    expect(body.dig("patient", "id")).to be_nil
    expect(DomainEvent.where(name: "clinical_record.viewed").count).to eq(0)
  end

  it "abertura: step-up, motivo, 30 min; leitura justificada; vencida 403 (Review Focus 5)" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    sign_in_as(nurse)
    json_post "/clinical_record/openings", cpf: citizen.cpf, reason_code: "case_review"
    expect(status_and_error).to eq([ 401, "mfa_required" ])
    step_up!(nurse)
    get "/clinical_record/patients/#{consultation.patient_id}"
    expect(status_and_error).to eq([ 403, "opening_required" ])
    json_post "/clinical_record/openings", cpf: "123.456.789-09", reason_code: "case_review"
    expect(status_and_error).to eq([ 404, "patient_not_found" ])
    json_post "/clinical_record/openings", cpf: citizen.cpf, reason_code: "other", reason_note: "curta"
    expect(status_and_error).to eq([ 422, "invalid_reason" ])
    json_post "/clinical_record/openings", cpf: citizen.cpf, reason_code: "active_search"
    expect(response).to have_http_status(:created)
    expect(body.keys).to match_array(%w[opening_id patient_id expires_at])
    get "/clinical_record/patients/#{consultation.patient_id}"
    expect([ response.status, body["access"] ]).to eq([ 200, "justified" ])
    travel_to(30.minutes.from_now + 1.second) do
      sign_in_as(nurse)
      get "/clinical_record/patients/#{consultation.patient_id}"
      expect(status_and_error).to eq([ 403, "opening_required" ])
    end
  end

  it "relatório das aberturas: municipal_admin, filtros, CPF mascarado, nunca a nota" do
    patient = Patients::Resolve.call(citizen).payload[:patient]
    now = Time.current
    ClinicalRecordOpening.create!(patient: patient, user: nurse, reason_code: "other", reason_note: "nota MARCADOR",
                                  created_at: now, expires_at: now + 30.minutes)
    sign_in_as(staff_with("adm-rel@cidade.gov.br", "municipal_admin"))
    get "/clinical_record/openings", params: { from: Time.zone.today.iso8601, to: Time.zone.today.iso8601, user_id: nurse.id }
    item = body["items"].sole
    expect(item.keys).to match_array(%w[id user_name cpf_masked reason_code created_at expires_at])
    expect(item.values_at("user_name", "cpf_masked", "reason_code")).to eq([ nurse.professional.professional_name, patient.cpf_masked, "other" ])
    expect(response.body).not_to include("MARCADOR")
    get "/clinical_record/openings", params: { from: "ontem" }
    expect(status_and_error).to eq([ 422, "invalid_period" ])
    get "/clinical_record/openings", params: { to: (Time.zone.today - 1).iso8601 }
    expect(body["items"]).to eq([])
    sign_in_as(doctor)
    get "/clinical_record/openings"
    expect(status_and_error).to eq([ 403, "missing_role" ])
  end

  it "a recepção recebe 403 em toda rota do prontuário" do
    consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen)
    attendance = consulting_attendance!(unit, citizen: citizen.reload, doctor: doctor)
    sign_in_as(reception!)
    [ [ :get, "/attendance/attendances/#{attendance.id}/record" ], [ :get, "/attendance/consultation_options" ],
      [ :post, "/attendance/attendances/#{attendance.id}/consultation" ], [ :get, "/attendance/consultations/#{consultation.id}" ],
      [ :patch, "/attendance/consultations/#{consultation.id}" ], [ :post, "/attendance/consultations/#{consultation.id}/finalize" ],
      [ :post, "/attendance/consultations/#{consultation.id}/addenda" ],
      [ :get, "/attendance/consultations/#{consultation.id}/print" ],
      [ :get, "/clinical_record/patients/#{consultation.patient_id}" ], [ :post, "/clinical_record/openings" ],
      [ :post, "/attendance/sigtap/search" ] ].each do |verb, path|
      send(verb, path, params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" })
      expect(response).to have_http_status(:forbidden), "#{verb} #{path}"
      expect(response.body).not_to include("Mariana", "Maria Aparecida", "Diabetes")
    end
  end
end
