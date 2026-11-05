require "rails_helper"

# Módulo 31 (contrato §4, P7, P13): acolhimento no CAPS, com ou sem
# encaminhamento; `enrolled` cria a matrícula na mesma transação. Resposta
# `{ reception_id, enrollment_id | null }`; encaminhamento já usado → 409
# referral_not_pending. Sem matrícula, o código é o 0301080232 (02 e 09): a
# Task 7 recusa código só 09 sem participante matriculado (preflight, 4 ↔ 7).
# Relógio fixo no arquivo inteiro: `started_on: Date.current` e `at: 1.hour.ago`
# caem em dias diferentes entre 00:00 e 01:00 locais.
RSpec.describe "CAPS — acolhimento", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.local(2026, 11, 18, 15, 0)) { example.run } }

  let!(:city) { psychosocial_city! }
  let(:caps) { caps! }
  let(:staff) { caps_staff!(caps) }
  let(:patient) { caps_patient! }
  let(:notes) { "Chegou acompanhado da irmã; aceita voltar na semana seguinte." }

  def referral!(of: patient, unit: caps)
    ubs = create_unit("UBS #{SecureRandom.hex(3)}")
    PsychosocialReferral.create!(patient: of, health_unit: unit, from_health_unit: ubs, referred_by_user: ubs_doctor!(ubs),
                                 reason: "Encaminhado pela UBS por sintomas persistentes", priority: "routine")
  end

  def enrollment_block(**over)
    { started_on: Date.current.iso8601, origin: "02", cid_main: "F20.0", cid_secondary: [], substances: [ "99" ], esf_covered: false,
      reference_user_id: staff.id }.merge(over)
  end

  def body(**over)
    { health_unit_id: caps.id, patient_id: patient.id, at: 1.hour.ago.iso8601, sigtap_code: "0301080232", notes: notes,
      outcome: "referred_elsewhere" }.merge(over)
  end

  before { sign_in_as(staff) }

  it "acolhe sem encaminhamento nem matrícula; o evento leva só o id" do
    json_post "/psychosocial/receptions", body
    expect(response).to have_http_status(:created)
    reception = PsychosocialReception.last
    expect(json_body).to eq("reception_id" => reception.id, "enrollment_id" => nil)
    expect(reception).to have_attributes(patient_id: patient.id, health_unit_id: caps.id, outcome: "referred_elsewhere",
                                         notes: notes, sigtap_code: "0301080232", recorded_by_user_id: staff.id)
    expect(DomainEvent.where(name: "psychosocial.reception_recorded").sole.payload).to eq("reception_id" => reception.id)
    expect(PsychosocialEnrollment.count).to eq(0)
  end

  # Task 7: o acolhimento é registrado como ação (origin "reception"), com o
  # instrumento do Desvio 3 e a crítica da ação, na mesma transação.
  it "sem matrícula, com 0301080232 (02 e 09): grava a ação BPA-I do acolhimento com o paciente" do
    json_post "/psychosocial/receptions", body
    expect(response).to have_http_status(:created)
    action = PsychosocialAction.sole
    expect(action).to have_attributes(origin: "reception", instrument: "bpa_i", sigtap_code: "0301080232", quantity: 1, place: "caps",
                                      professional_user_id: staff.id, cbo_code: "251510", notes: nil)
    expect(action.psychosocial_action_participants.map { |p| [ p.position, p.patient_id, p.psychosocial_enrollment_id ] })
      .to eq([ [ 1, patient.id, nil ] ])
    expect(DomainEvent.where(name: "psychosocial.action_recorded").sole.payload).to eq("action_id" => action.id)
  end

  it "com a matrícula: a ação do acolhimento é RAAS com o participante matriculado" do
    json_post "/psychosocial/receptions", body(outcome: "enrolled", enrollment: enrollment_block)
    expect(response).to have_http_status(:created)
    participant = PsychosocialAction.sole.psychosocial_action_participants.sole
    expect(PsychosocialAction.sole.instrument).to eq("raas_psi")
    expect(participant.psychosocial_enrollment_id).to eq(json_body["enrollment_id"])
  end

  it "código só 09 sem matrícula → 422 action_rejected enrollment_required; nada gravado" do
    referral = referral!
    expect do
      json_post "/psychosocial/receptions", body(sigtap_code: "0301080208", referral_id: referral.id)
    end.not_to change { [ PsychosocialReception.count, PsychosocialAction.count, DomainEvent.count ] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "action_rejected",
                                                          "problems" => [ { "error" => "enrollment_required", "path" => "sigtap_code" } ] } ])
    expect(referral.reload.status).to eq("pending")
  end

  it "`at` antes do início da matrícula criada → 422 action_rejected enrollment_required em at; nada gravado" do
    patient
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", at: Time.zone.local(2026, 11, 17, 10).iso8601,
                                                 enrollment: enrollment_block(started_on: "2026-11-18"))
    end.not_to change { [ PsychosocialReception.count, PsychosocialEnrollment.count, PsychosocialAction.count, DomainEvent.count ] }
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "action_rejected",
                                                          "problems" => [ { "error" => "enrollment_required", "path" => "at" } ] } ])
  end

  it "CBO de quem acolhe fora da lista do código → action_rejected cbo_incompatible" do
    sign_in_as(caps_staff!(caps, cbo: "515105"))
    json_post "/psychosocial/receptions", body
    expect(json_body).to eq("error" => "action_rejected", "problems" => [ { "error" => "cbo_incompatible", "path" => "sigtap_code" } ])
    expect(PsychosocialReception.count).to eq(0)
  end

  it "`enrolled` sem o bloco `enrollment` → invalid_request enrollment; com outro desfecho o bloco é recusado" do
    json_post "/psychosocial/receptions", body(outcome: "enrolled")
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "enrollment" ])
    json_post "/psychosocial/receptions", body(outcome: "no_follow_up", enrollment: enrollment_block)
    expect(json_body["path"]).to eq("enrollment")
    expect(PsychosocialReception.count).to eq(0)
  end

  it "com o bloco: recepção e matrícula juntas, o encaminhamento passa a received; o segundo uso → 409" do
    referral = referral!
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", referral_id: referral.id, enrollment: enrollment_block)
    end.to change(PsychosocialMonthlyRecord, :count).by(1)
    expect(response).to have_http_status(:created)
    enrollment = PsychosocialEnrollment.find(json_body["enrollment_id"])
    expect(enrollment.psychosocial_reception_id).to eq(json_body["reception_id"])
    expect(PsychosocialReception.find(json_body["reception_id"]).psychosocial_referral_id).to eq(referral.id)
    expect(referral.reload).to have_attributes(status: "received", received_at: be_present)
    expect(DomainEvent.where(name: "psychosocial.enrolled").sole.payload).to eq("enrollment_id" => enrollment.id)

    json_post "/psychosocial/receptions", body(referral_id: referral.id)
    expect([ response.status, json_body["error"] ]).to eq([ 409, "referral_not_pending" ])
  end

  it "falha na matrícula desfaz a recepção e mantém o encaminhamento pendente" do
    enrollment!(caps, patient: patient, reference: staff)
    referral = referral!
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", referral_id: referral.id, enrollment: enrollment_block)
    end.not_to change(PsychosocialReception, :count)
    expect([ response.status, json_body["error"] ]).to eq([ 409, "enrollment_open" ])
    expect(referral.reload.status).to eq("pending")
    expect(DomainEvent.where(name: "psychosocial.reception_recorded")).to be_empty
  end

  it "início da matrícula em mês fechado → 422 month_closed enrollment.started_on, nada gravado" do
    start = Date.current.beginning_of_month.prev_month
    PsychosocialMonthClosure.create!(health_unit: caps, month: start, closed_at: Time.current, closed_by_user: staff)
    referral = referral!
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", referral_id: referral.id,
                                                 enrollment: enrollment_block(started_on: (start + 2).iso8601))
    end.not_to change { [ PsychosocialReception.count, PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count, DomainEvent.count ] }
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "enrollment.started_on" ])
    expect(json_body["problems"]).to eq([ { "error" => "month_closed", "path" => "enrollment.started_on" } ])
    expect(referral.reload.status).to eq("pending")
  end

  it "matrícula retroativa no acolhimento: a RAAS de cada mês; mês intermediário fechado → month_closed enrollment.started_on" do
    json_post "/psychosocial/receptions", body(outcome: "enrolled", enrollment: enrollment_block(started_on: "2026-09-12"))
    expect(response).to have_http_status(:created)
    expect(PsychosocialMonthlyRecord.where(psychosocial_enrollment_id: json_body["enrollment_id"]).order(:month).pluck(:month))
      .to eq([ Date.new(2026, 9, 1), Date.new(2026, 10, 1), Date.new(2026, 11, 1) ])

    PsychosocialMonthClosure.create!(health_unit: caps, month: Date.new(2026, 10, 1), closed_at: Time.current, closed_by_user: staff)
    other = caps_patient!
    expect do
      json_post "/psychosocial/receptions", body(patient_id: other.id, outcome: "enrolled", enrollment: enrollment_block(started_on: "2026-09-12"))
    end.not_to change { [ PsychosocialReception.count, PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count, DomainEvent.count ] }
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "month_closed", "enrollment.started_on" ])
  end

  it "início da matrícula antes do piso (13 meses) ou do nascimento → invalid_request enrollment.started_on, nada gravado" do
    patient && staff
    unchanged = -> { [ PsychosocialReception.count, PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count, DomainEvent.count ] }
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", enrollment: enrollment_block(started_on: "2025-10-31"))
    end.not_to(change(&unchanged))
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "enrollment.started_on" ])

    patient.update!(birth_date: "2026-10-05")
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", enrollment: enrollment_block(started_on: "2026-09-12"))
    end.not_to(change(&unchanged))
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "invalid_request", "enrollment.started_on" ])
  end

  it "corrida na matrícula aberta (índice único) desfaz a recepção: 409 enrollment_open, nada gravado" do
    enrollment!(caps, patient: patient, reference: staff)
    referral = referral!
    allow(PsychosocialEnrollment).to receive(:open_enrollments).and_return(PsychosocialEnrollment.none)
    expect do
      json_post "/psychosocial/receptions", body(outcome: "enrolled", referral_id: referral.id, enrollment: enrollment_block)
    end.not_to change { [ PsychosocialReception.count, PsychosocialEnrollment.count, PsychosocialMonthlyRecord.count, DomainEvent.count ] }
    expect([ response.status, json_body["error"] ]).to eq([ 409, "enrollment_open" ])
    expect(referral.reload.status).to eq("pending")
  end

  it "os problemas do bloco vêm com o prefixo enrollment., junto com os da recepção" do
    json_post "/psychosocial/receptions", body(outcome: "enrolled", at: 1.hour.from_now.iso8601,
                                               enrollment: enrollment_block(origin: "77", esf_covered: true, patient_id: patient.id))
    expect(json_body["problems"].map { |p| p["path"] })
      .to contain_exactly("at", "enrollment.origin", "enrollment.esf_cnes", "enrollment.patient_id")
  end

  it "encaminhamento de outro paciente ou de outro CAPS → invalid_request referral_id" do
    json_post "/psychosocial/receptions", body(referral_id: referral!(of: caps_patient!).id)
    expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "referral_id" ])
    json_post "/psychosocial/receptions", body(referral_id: referral!(unit: caps!(modality: "caps_ad")).id)
    expect(json_body["path"]).to eq("referral_id")
  end

  it "`at` futuro → invalid_request at" do
    json_post "/psychosocial/receptions", body(at: 10.minutes.from_now.iso8601)
    expect([ json_body["error"], json_body["path"] ]).to eq([ "invalid_request", "at" ])
  end

  it "código fora de RAAS-PSI e BPA-I → instrument_mismatch" do
    json_post "/psychosocial/receptions", body(sigtap_code: "0301080259")
    expect([ json_body["error"], json_body["path"] ]).to eq([ "instrument_mismatch", "sigtap_code" ])
    json_post "/psychosocial/receptions", body(sigtap_code: "0399999999")
    expect(json_body["error"]).to eq("instrument_mismatch")
  end

  it "notas acima de 4000 caracteres → too_long" do
    json_post "/psychosocial/receptions", body(notes: "a" * 4001)
    expect([ response.status, json_body["error"], json_body["path"] ]).to eq([ 422, "too_long", "notes" ])
    expect(response.body).not_to include("a" * 100)
  end

  it "fora do CAPS de lotação → 403 not_on_caps_team" do
    json_post "/psychosocial/receptions", body(health_unit_id: caps!(modality: "caps_ad").id)
    expect([ response.status, json_body["error"] ]).to eq([ 403, "not_on_caps_team" ])
  end
end
