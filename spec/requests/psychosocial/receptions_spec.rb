require "rails_helper"

# Módulo 31 (contrato §4, P7, P13): acolhimento no CAPS, com ou sem
# encaminhamento; `enrolled` cria a matrícula na mesma transação. Resposta
# `{ reception_id, enrollment_id | null }`; encaminhamento já usado → 409
# referral_not_pending. Sem matrícula, o código é o 0301080232 (02 e 09): a
# Task 7 recusa código só 09 sem participante matriculado (preflight, 4 ↔ 7).
RSpec.describe "CAPS — acolhimento", type: :request do
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
    expect(DomainEvent.where(name: "psychosocial.reception_recorded").last.payload).to eq("reception_id" => reception.id)
    expect(PsychosocialEnrollment.count).to eq(0)
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
    expect(DomainEvent.where(name: "psychosocial.enrolled").last.payload).to eq("enrollment_id" => enrollment.id)

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
