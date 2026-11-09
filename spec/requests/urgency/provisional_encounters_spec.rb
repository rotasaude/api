require "rails_helper"

# Módulo 32a (ADR 0050; contrato §14 Q25, Q29): GET
# /urgency/provisional_encounters?health_unit_id= — a lista da recepção da UPA
# (citizen_verifier) dos encontros com paciente provisório ainda não
# identificado (nem fundido): os abertos que chegaram nos últimos 7 dias e os
# fechados nos últimos 7 dias (pelo closed_at), sem o registro por engano.
# Cada item `{ encounter_id, attendance_id, arrived_at, closed_at,
# outcome_kind, patient: <patient-ref com description> }`, sem dado clínico;
# uma trilha por paciente listado (resource provisional_encounters).
RSpec.describe "Provisórios para identificar", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:reception) { upa_reception! }
  let(:path) { "/urgency/provisional_encounters" }

  def list!(query = { health_unit_id: upa.id }) = get(path, params: query)
  def items = json_body["items"]
  def ids = items.map { |item| item["encounter_id"] }

  def left!(encounter, kind: "left_without_care", reason: nil)
    attrs = { "kind" => kind }
    attrs["reason"] = reason if reason
    result = Urgency::RecordOutcome.call(encounter: encounter.reload, attrs: attrs, by: reception)
    raise "desfecho recusado: #{result.reason}" if result.failure?

    encounter.reload
  end

  def identify!(encounter, **args)
    result = Urgency::Identify.call(encounter: encounter.reload, by: reception, **args)
    raise "identificação recusada: #{result.reason}" if result.failure?
  end

  def viewed_events
    DomainEvent.where(name: "clinical_record.viewed").where("payload->>'resource' = 'provisional_encounters'")
  end

  it "só os provisórios não identificados da janela, sem dado clínico, com uma trilha por paciente" do
    stale_open = travel_to(8.days.ago) { arrived!(upa, unidentified: "Homem, chegou há oito dias") }
    stale_closed = travel_to(9.days.ago) { left!(arrived!(upa, unidentified: "Mulher, saiu há nove dias")) }
    late_closed = travel_to(10.days.ago) { arrived!(upa, unidentified: "Idoso, chegou há dez dias") }
    travel_to(6.days.ago) { left!(late_closed) }
    waiting = arrived!(upa, unidentified: "Homem, 40 anos, tatuagem no braço")
    classified = arrived!(upa, unidentified: "Mulher jovem de casaco azul")
                 .tap { |e| classified!(e, color: "yellow", by: nurse, justification: "Queixa de dor abdominal forte") }
    gone = left!(arrived!(upa, unidentified: "Adolescente de boné vermelho"))
    error = left!(arrived!(upa, unidentified: "Chegada lançada duas vezes"), kind: "registered_in_error",
                  reason: "Aberto em duplicidade com outra senha")
    merged = arrived!(upa, unidentified: "Senhor de bengala")
    identify!(merged, patient_id: urgency_patient!(1).id)
    renamed = arrived!(upa, unidentified: "Senhora de óculos")
    identify!(renamed, new_patient: { "full_name" => "Benedita Ramos", "birth_date" => "1950-03-03", "sex" => "female",
                                      "no_cpf_reason" => "3" })
    known = arrived!(upa, patient: urgency_patient!(2))
    elsewhere = arrived!(upa!, unidentified: "Homem em outra UPA")

    sign_in_as(reception)
    list!
    expect(response).to have_http_status(:ok)
    expect(json_body.keys).to eq([ "items" ])
    expect(ids).to contain_exactly(waiting.id, classified.id, gone.id, late_closed.id)
    [ stale_open, stale_closed, error, merged, renamed, known, elsewhere ].each { |e| expect(ids).not_to include(e.id) }

    item = items.find { |i| i["encounter_id"] == classified.id }
    expect(item.keys).to contain_exactly("encounter_id", "attendance_id", "arrived_at", "closed_at", "outcome_kind", "patient")
    expect(item).to include("attendance_id" => classified.attendance_id, "arrived_at" => classified.attendance.checked_in_at.iso8601,
                            "closed_at" => nil, "outcome_kind" => nil)
    provisional = classified.patient
    expect(item["patient"]).to eq("patient_id" => provisional.id, "name" => provisional.display_name,
                                  "cns_masked" => provisional.cns_masked, "unidentified" => true,
                                  "description" => "Mulher jovem de casaco azul")
    closed = items.find { |i| i["encounter_id"] == gone.id }
    expect(closed).to include("outcome_kind" => "left_without_care", "closed_at" => gone.attendance.reload.closed_at.iso8601)
    expect(items.find { |i| i["encounter_id"] == late_closed.id }["closed_at"]).to be_present
    # Nenhum dado clínico: nem cor, nem queixa, nem justificativa, nem o motivo do engano.
    expect(response.body).not_to include("yellow", UrgencyHelpers::COMPLAINT, "Queixa de dor abdominal", "duplicidade")

    trail = viewed_events
    expect(trail.map { |e| e.payload["patient_id"] })
      .to contain_exactly(*[ waiting, classified, gone, late_closed ].map { |e| e.patient.id })
    expect(trail.first.payload).to include("user_id" => reception.id, "access" => "urgency",
                                           "person_ref" => "patient:#{trail.first.payload['patient_id']}")
  end

  it "lista vazia não grava trilha" do
    arrived!(upa, patient: urgency_patient!(3))
    sign_in_as(reception)
    list!
    expect(response).to have_http_status(:ok)
    expect(json_body).to eq("items" => [])
    expect(viewed_events).to be_empty
  end

  it "só a recepção lê: enfermagem, médico e o admin → 403 missing_role, sem trilha" do
    arrived!(upa, unidentified: "Homem, 40 anos, tatuagem no braço")
    [ nurse, doctor, urgency_admin! ].each do |user|
      sign_in_as(user)
      list!
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "missing_role")
    end
    expect(viewed_events).to be_empty
  end

  it "a unidade: obrigatória, existente, UPA e nunca CAPS; só ela na query" do
    sign_in_as(reception)
    list!({})
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to eq("error" => "invalid_request", "path" => "health_unit_id",
                            "problems" => [ { "path" => "health_unit_id", "error" => "invalid_request" } ])
    list!(health_unit_id: "x")
    expect(response).to have_http_status(:not_found)
    list!(health_unit_id: SecureRandom.uuid)
    expect(response).to have_http_status(:not_found)
    caps = HealthUnit.create!(name: "CAPS X #{SecureRandom.hex(2)}", kind: "caps", caps_modality: "caps_ii")
    list!(health_unit_id: caps.id)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to eq("error" => "caps_unit_not_allowed")
    list!(health_unit_id: create_unit("UBS Y #{SecureRandom.hex(2)}").id)
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body).to eq("error" => "not_an_upa")
    patient = urgency_patient!(4)
    %w[cpf cns name].each do |key|
      value = { "cpf" => patient.cpf, "cns" => patient.cns, "name" => patient.full_name }[key]
      list!(health_unit_id: upa.id, key => value)
      expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", key ])
      expect(response.body).not_to include(value)
    end
  end

  it "urgency_care desligado → 403 feature_disabled" do
    Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(reception)
    list!
    expect(response).to have_http_status(:forbidden)
    expect(json_body).to eq("error" => "feature_disabled", "feature" => "urgency_care")
  end
end
