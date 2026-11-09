require "rails_helper"

# Módulo 32a (ADR 0050; contrato §4, §14 Q4, Q15): busca de pessoa e chegada
# na UPA pela recepção (citizen_verifier).
RSpec.describe "Chegada na UPA", type: :request do
  let!(:city) { urgency_city!(waiting_room: true) }
  let(:upa) { upa! }
  before { sign_in_as(upa_reception!) }

  it "paciente achado pelo CPF chega com senha; a mesma pessoa não abre dois encontros na UPA" do
    patient = urgency_patient!(1)
    json_post "/urgency/person_lookup", cpf: patient.cpf
    expect(json_body["patient"]).to include("patient_id" => patient.id, "unidentified" => false)
    expect(json_body["patient"].keys).to contain_exactly("patient_id", "name", "cns_masked", "unidentified")
    expect { json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: patient.id }
      .to change(UrgencyEncounter, :count).by(1).and change { DomainEvent.where(name: "urgency.arrived").count }.by(1)
    expect(response).to have_http_status(:created)
    expect(json_body).to include("ticket" => "U-001")
    expect(UrgencyEncounter.last.state).to eq("waiting_classification")
    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: patient.id
    expect(response).to have_http_status(:conflict)
    expect(json_body["error"]).to eq("encounter_open")
  end

  it "não identificado: paciente provisório com descrição, sem CPF; nada da descrição no evento nem no log" do
    log = capture_log do
      json_post "/urgency/arrivals", health_unit_id: upa.id, unidentified: { description: "Mulher, cerca de 70 anos, trazida pelo SAMU" }
    end
    expect(json_body["patient"]).to include("unidentified" => true, "name" => "Paciente não identificado")
    expect(json_body["patient"]).not_to have_key("description")
    expect(Patient.find(json_body.dig("patient", "patient_id")).no_cpf_reason).to eq("unidentified")
    expect(log).not_to include("SAMU")
    expect(DomainEvent.where(name: %w[urgency.arrived attendance.checked_in]).map(&:payload).to_s).not_to include("SAMU")
  end

  it "paciente novo pelo 24a; recusas na ordem: forma, CAPS, não UPA" do
    json_post "/urgency/arrivals", health_unit_id: upa.id,
              new_patient: { full_name: "Joana Ribeiro Matos", birth_date: "1975-04-03", sex: "female", no_cpf_reason: "3" }
    expect(response).to have_http_status(:created)
    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: urgency_patient!(2).id, unidentified: { description: "Duas formas juntas" }
    expect(json_body).to include("error" => "invalid_request", "path" => "patient")
    caps = HealthUnit.create!(name: "CAPS X", kind: "caps", caps_modality: "caps_ii")
    json_post "/urgency/arrivals", health_unit_id: caps.id, patient_id: urgency_patient!(3).id
    expect(json_body["error"]).to eq("caps_unit_not_allowed")
    json_post "/urgency/arrivals", health_unit_id: create_unit("UBS Y").id, patient_id: urgency_patient!(4).id
    expect(json_body["error"]).to eq("not_an_upa")
  end

  it "provisório não serve a outra chegada; busca pela query é recusada; interruptor desligado → 403" do
    provisional = arrived!(upa, unidentified: "Homem, 30 anos").patient
    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: provisional.id
    expect(json_body["path"]).to eq("patient_id")
    post "/urgency/person_lookup?cpf=52998224725", params: {}.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(json_body["path"]).to eq("cpf")
    Platform::Features.set!(city: city, key: "urgency_care", enabled: false, maintainer: ledi_maintainer!)
    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: urgency_patient!(5).id
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
  end

  # Contrato §14 Q4 e Q15 (preflight C-20): busca sem ninguém é 200; a busca
  # que acha grava a trilha da urgência; patient_id inexistente é 404.
  it "busca sem ninguém é 200 com patient nulo; a que acha grava a trilha; patient_id desconhecido → 404" do
    json_post "/urgency/person_lookup", cpf: urgency_cpf(77)
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("patient" => nil, "candidates" => [])

    patient = urgency_patient!(6)
    expect { json_post "/urgency/person_lookup", cns: patient.cns }
      .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
    expect(json_body["candidates"]).to eq([])
    expect(DomainEvent.where(name: "clinical_record.viewed").last.payload)
      .to include("patient_id" => patient.id, "access" => "urgency", "resource" => "person_lookup",
                  "person_ref" => "patient:#{patient.id}")

    json_post "/urgency/person_lookup", cpf: urgency_cpf(78), name: "x"
    expect(json_body).to include("error" => "invalid_request", "path" => "name")

    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: SecureRandom.uuid
    expect(response).to have_http_status(:not_found)
    expect(json_body).to eq("error" => "patient_not_found", "path" => "patient_id")
  end

  it "recusas de campo com o path (P23); sem a sala de espera, sem senha; sem o papel da recepção → 403" do
    json_post "/urgency/arrivals", health_unit_id: upa.id, unidentified: { description: "curta" }
    expect(json_body).to include("error" => "invalid_request", "path" => "unidentified.description",
                                 "problems" => [ { "path" => "unidentified.description", "error" => "invalid_request" } ])
    json_post "/urgency/arrivals", health_unit_id: upa.id, new_patient: { full_name: "Joana Ribeiro Matos", birth_date: "1975-04-03", sex: "female" }
    expect(json_body).to include("error" => "cpf_or_reason_required", "path" => "new_patient.no_cpf_reason")
    expect { json_post "/urgency/arrivals", health_unit_id: upa.id, new_patient: { full_name: "Joana Ribeiro Matos", birth_date: "1975-04-03", sex: "x", no_cpf_reason: "3" } }
      .not_to change(Patient, :count)
    expect(json_body).to include("error" => "invalid_patient", "path" => "new_patient.sex")

    Platform::Features.set!(city: city, key: "waiting_room_display", enabled: false, maintainer: ledi_maintainer!)
    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: urgency_patient!(7).id
    expect(response).to have_http_status(:created)
    expect(json_body["ticket"]).to be_nil
    expect(json_body.keys).to contain_exactly("attendance_id", "encounter_id", "ticket", "patient")
    expect(Attendance.find(json_body["attendance_id"])).to have_attributes(origin_kind: "walk_in", status: "waiting",
                                                                           check_in_method: "urgency_reception", citizen_id: nil)

    sign_in_as(upa_nurse!(upa))
    json_post "/urgency/arrivals", health_unit_id: upa.id, patient_id: urgency_patient!(8).id
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "missing_role")
  end
end
