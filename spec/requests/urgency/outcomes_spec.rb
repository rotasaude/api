require "rails_helper"

# Módulo 32a (ADR 0050; contrato §7 e §14 Q10, Q11, Q15, Q19, Q20, Q25;
# plano, Desvio 13): o desfecho fecha o encontro e o atendimento do 13 com o
# `outcome` equivalente; o fechamento direto do 13 numa UPA exige o desfecho
# (só com urgency_care utilizável); a alta para a UBS vira a lista de retornos
# da UBS de referência do paciente, sem o motivo.
RSpec.describe "Desfecho do atendimento de urgência", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:patient) { urgency_patient!(1) }
  let(:encounter) { arrived!(upa, patient: patient).tap { |e| classified!(e, color: "green", by: nurse, pain_scale: 5) } }

  before { ciap2_release!; cid10_release!; sigtap_release! }

  def outcome!(target = encounter, **body) = json_post("/urgency/encounters/#{target.id}/outcome", body)

  # O desfecho tem de estar no detalhe e nunca em evento algum (só ids).
  def closed_event_for(target) = DomainEvent.where(name: "urgency.encounter_closed").find { |e| e.payload["encounter_id"] == target.id }

  it "alta com retorno à UBS fecha o 13 como referred, sem o motivo em texto claro, e avisa a UBS da equipe" do
    patient, ubs, team = patient_with_team!
    encounter = arrived!(upa, patient: patient).tap { |e| classified!(e, color: "green", by: nurse, pain_scale: 5) }
    called!(encounter, by: doctor)
    finalized_urgency!(encounter, doctor: doctor)
    sign_in_as(doctor)
    outcome!(encounter, kind: "discharged_to_primary_care", return_guidance: { days: 7, reason: "Reavaliar pressão arterial após ajuste" })
    expect(response).to have_http_status(:created)
    expect(json_body["encounter"]).to include("id" => encounter.id, "state" => "closed")
    expect(json_body.dig("encounter", "outcome")).to include("kind" => "discharged_to_primary_care",
                                                             "return_guidance" => { "days" => 7, "reason" => "Reavaliar pressão arterial após ajuste" })
    expect(json_body["attendance"]).to include("id" => encounter.attendance_id, "status" => "closed", "outcome" => "referred")
    attendance = encounter.attendance.reload
    expect(attendance).to have_attributes(status: "closed", outcome: "referred", referral_note: "Retorno à UBS em até 7 dias",
                                          referral_regulated: false, referral_unit_id: nil)
    expect(encounter.reload.outcome).to have_attributes(counter_referral_health_team_id: team.id, counter_referral_health_unit_id: ubs.id,
                                                        return_days: 7)
    raw = ApplicationRecord.connection.select_value("SELECT return_reason FROM urgency_outcomes WHERE id = '#{encounter.outcome.id}'")
    expect(raw).not_to include("pressão")
    expect(closed_event_for(encounter).payload.keys).to eq([ "encounter_id" ])

    sign_in_as(doctor!(ubs))
    get "/urgency/counter_referrals", params: { health_unit_id: ubs.id }
    expect(response).to have_http_status(:ok)
    item = json_body["items"].first
    expect(item).to include("encounter_id" => encounter.id, "return_days" => 7, "upa" => { "name" => upa.name },
                            "closed_at" => attendance.closed_at.iso8601, "due_on" => (attendance.closed_at.to_date + 7).iso8601)
    expect(item["patient"]).to include("patient_id" => patient.id, "unidentified" => false)
    expect(response.body).not_to include("pressão")
  end

  # Contrato §14 Q26: "em até 1 dia" no singular; "em até N dias" de 2 em diante.
  it "retorno à UBS em 1 dia leva a nota no singular" do
    called!(encounter, by: doctor)
    finalized_urgency!(encounter, doctor: doctor)
    sign_in_as(doctor)
    outcome!(encounter, kind: "discharged_to_primary_care", return_guidance: { days: 1, reason: "Reavaliar a febre amanhã" })
    expect(response).to have_http_status(:created)
    expect(encounter.attendance.reload.referral_note).to eq("Retorno à UBS em até 1 dia")
  end

  it "evasão vale antes e depois da chamada; os demais exigem a consulta finalizada" do
    sign_in_as(upa_reception!)
    outcome!(kind: "left_without_care")
    expect(response).to have_http_status(:created)
    expect(encounter.attendance.reload).to have_attributes(status: "closed", outcome: "left")
    # Recepção sem acesso clínico (Q19): o detalhe sem o clínico.
    expect(json_body.dig("encounter", "classifications", 0)).not_to include("complaint", "vital_signs", "pain_scale")
    other = arrived!(upa, patient: urgency_patient!(2)).tap { |e| classified!(e, color: "yellow", by: nurse, justification: "Conferido na classificação") }
    called!(other, by: doctor)
    sign_in_as(doctor)
    outcome!(other, kind: "discharged")
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["error"]).to eq("consultation_not_finalized")
    outcome!(other, kind: "left_without_care")
    expect(response).to have_http_status(:created)
    expect(other.attendance.reload).to have_attributes(status: "closed", outcome: "left")
    expect(other.reload.state).to eq("closed")
  end

  it "transferência exige destino e fecha como referred regulado; alta de provisório é recusada, óbito não" do
    called!(encounter, by: doctor)
    finalized_urgency!(encounter, doctor: doctor)
    sign_in_as(doctor)
    outcome!(kind: "transferred")
    expect(json_body).to include("error" => "destination_required", "path" => "destination")
    outcome!(kind: "transferred", destination: "HT")
    expect(json_body).to include("error" => "invalid_request", "path" => "destination")
    outcome!(kind: "transferred", destination: "Hospital do Trabalhador", vacancy_request: "Vaga pedida às 14h")
    expect(response).to have_http_status(:created)
    expect(json_body.dig("encounter", "outcome")).to include("destination" => "Hospital do Trabalhador")
    expect(encounter.attendance.reload).to have_attributes(outcome: "referred", referral_regulated: true, referral_note: nil)
    expect(AppointmentRequest.where(origin_attendance_id: encounter.attendance_id)).to be_empty
    unknown = arrived!(upa, unidentified: "Homem idoso").tap { |e| classified!(e, color: "red", by: nurse, vital_signs: { spo2: 80 }) }
    called!(unknown, by: doctor)
    finalized_urgency!(unknown, doctor: doctor)
    outcome!(unknown, kind: "discharged")
    expect(json_body["error"]).to eq("patient_unidentified")
    outcome!(unknown, kind: "death")
    expect(response).to have_http_status(:created)
    expect(unknown.attendance.reload).to have_attributes(status: "closed", outcome: "discharged")
  end

  it "o fechamento direto do 13 numa UPA exige o desfecho do 32" do
    called!(encounter, by: doctor)
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{encounter.attendance_id}/close", outcome: "discharged"
    expect(response).to have_http_status(:unprocessable_content)
    expect(json_body["error"]).to eq("urgency_outcome_required")
    expect(encounter.attendance.reload.status).to eq("in_care")
  end

  it "com urgency_care desligado o 13 fecha o walk_in como antes, sem pedido de agenda e sem tocar o encontro" do
    called!(encounter, by: doctor)
    ubs = create_unit("UBS Destino #{SecureRandom.hex(2)}")
    Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
    CityCatalog.reset_cache!
    sign_in_as(doctor)
    json_post "/attendance/attendances/#{encounter.attendance_id}/close", outcome: "referred", referral_unit_id: ubs.id
    expect(response).to have_http_status(:ok)
    expect(json_body["appointment_request"]).to be_nil
    expect(encounter.attendance.reload).to have_attributes(status: "closed", outcome: "referred", referral_unit_id: ubs.id)
    expect(encounter.reload).to have_attributes(state: "in_care", outcome: nil)
  end

  describe "quem registra" do
    it "a recepção e a enfermagem só registram a evasão e o registro por engano; o médico, todos" do
      called!(encounter, by: doctor)
      finalized_urgency!(encounter, doctor: doctor)
      sign_in_as(upa_reception!)
      outcome!(kind: "discharged")
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_role")
      sign_in_as(nurse)
      outcome!(kind: "death")
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("cbo_not_allowed")
      technician = upa_nurse!(upa, cbo: "322205")
      sign_in_as(technician)
      outcome!(kind: "left_without_care")
      expect(json_body["error"]).to eq("cbo_not_allowed")
      sign_in_as(doctor!(create_unit("UBS Longe #{SecureRandom.hex(2)}")))
      outcome!(kind: "left_without_care")
      expect(json_body["error"]).to eq("missing_link")
      expect(encounter.reload.state).to eq("in_care")
      sign_in_as(doctor)
      outcome!(kind: "discharged")
      expect(response).to have_http_status(:created)
      expect(encounter.attendance.reload).to have_attributes(status: "closed", outcome: "discharged")
    end

    it "a enfermagem registra a evasão de quem espera a classificação, com o detalhe clínico" do
      waiting = arrived!(upa, patient: urgency_patient!(3))
      sign_in_as(nurse)
      outcome!(waiting, kind: "left_without_care")
      expect(response).to have_http_status(:created)
      expect(waiting.reload.state).to eq("closed")
      expect(waiting.attendance.reload).to have_attributes(status: "closed", outcome: "left")
    end
  end

  describe "registrado por engano (Q25)" do
    it "fecha como left em qualquer estado, com o motivo cifrado e fora do evento e da resposta sem acesso clínico" do
      duplicate = arrived!(upa, patient: urgency_patient!(4))
      sign_in_as(upa_reception!)
      outcome!(duplicate, kind: "registered_in_error")
      expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      outcome!(duplicate, kind: "registered_in_error", reason: "curto")
      expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      outcome!(duplicate, kind: "left_without_care", reason: "Chegada duplicada pela recepção")
      expect(json_body).to include("error" => "invalid_request", "path" => "reason")
      log = capture_log { outcome!(duplicate, kind: "registered_in_error", reason: "Chegada duplicada pela recepção") }
      expect(response).to have_http_status(:created)
      expect(log).not_to include("duplicada")
      expect(response.body).not_to include("duplicada")
      expect(json_body.dig("encounter", "outcome", "kind")).to eq("registered_in_error")
      expect(duplicate.attendance.reload).to have_attributes(status: "closed", outcome: "left")
      expect(duplicate.reload.outcome.error_reason).to eq("Chegada duplicada pela recepção")
      raw = ApplicationRecord.connection.select_value("SELECT error_reason FROM urgency_outcomes WHERE id = '#{duplicate.outcome.id}'")
      expect(raw).not_to include("duplicada")
      expect(closed_event_for(duplicate).payload.keys).to eq([ "encounter_id" ])
    end

    it "vale para o provisório e com o paciente já com o médico, sem consulta" do
      unknown = arrived!(upa, unidentified: "Mulher jovem de casaco azul").tap { |e| classified!(e, color: "blue", by: nurse) }
      called!(unknown, by: doctor)
      sign_in_as(nurse)
      outcome!(unknown, kind: "registered_in_error", reason: "Aberto em duplicidade com outra senha")
      expect(response).to have_http_status(:created)
      expect(json_body.dig("encounter", "outcome")).to include("reason" => "Aberto em duplicidade com outra senha")
      expect(unknown.attendance.reload).to have_attributes(status: "closed", outcome: "left")
    end
  end

  describe "recusas de forma e de estado" do
    before do
      called!(encounter, by: doctor)
      finalized_urgency!(encounter, doctor: doctor)
      sign_in_as(doctor)
    end

    it "retorno à UBS exige a orientação; campos de outro desfecho e chaves desconhecidas são recusados" do
      outcome!(kind: "discharged_to_primary_care")
      expect(json_body).to include("error" => "return_guidance_required", "path" => "return_guidance")
      outcome!(kind: "discharged_to_primary_care", return_guidance: { days: 0, reason: "Curativo da ferida" })
      expect(json_body).to include("error" => "invalid_request", "path" => "return_guidance.days")
      outcome!(kind: "discharged_to_primary_care", return_guidance: { days: 7, reason: "ok" })
      expect(json_body).to include("error" => "invalid_request", "path" => "return_guidance.reason")
      outcome!(kind: "discharged", destination: "Hospital do Trabalhador")
      expect(json_body).to include("error" => "invalid_request", "path" => "destination")
      outcome!(kind: "discharged", vacancy_request: "Vaga 1")
      expect(json_body).to include("error" => "invalid_request", "path" => "vacancy_request")
      outcome!(kind: "discharged", return_guidance: { days: 7, reason: "Curativo da ferida" })
      expect(json_body).to include("error" => "invalid_request", "path" => "return_guidance")
      outcome!(kind: "escaped")
      expect(json_body).to include("error" => "invalid_request", "path" => "kind")
      outcome!(kind: "discharged", extra: 1)
      expect(json_body).to include("error" => "invalid_request", "path" => "extra")
      expect(encounter.reload.outcome).to be_nil
    end

    it "um desfecho só: o segundo é encounter_closed" do
      outcome!(kind: "discharged")
      expect(response).to have_http_status(:created)
      outcome!(kind: "death")
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("encounter_closed")
    end
  end

  it "evasão com a consulta em rascunho é consultation_in_progress e não grava nada" do
    urgency_consultation!(encounter, doctor: doctor)
    sign_in_as(doctor)
    outcome!(kind: "left_without_care")
    expect(response).to have_http_status(:conflict)
    expect(json_body["error"]).to eq("consultation_in_progress")
    expect(encounter.reload).to have_attributes(state: "in_care", outcome: nil)
  end

  describe "retornos pedidos pela urgência (GET /urgency/counter_referrals)" do
    it "a recepção lê; o profissional sem vínculo na UBS não; só os últimos 60 dias, do mais recente ao mais antigo" do
      patient, ubs, team = patient_with_team!
      first = arrived!(upa, patient: patient).tap { |e| classified!(e, color: "green", by: nurse, pain_scale: 5) }
      called!(first, by: doctor)
      finalized_urgency!(first, doctor: doctor)
      result = Urgency::RecordOutcome.call(encounter: first.reload, by: doctor, team: team,
                                           attrs: { "kind" => "discharged_to_primary_care", "return_guidance" => { "days" => 5, "reason" => "Curativo" } })
      raise result.reason.to_s if result.failure?

      sign_in_as(upa_reception!)
      get "/urgency/counter_referrals", params: { health_unit_id: ubs.id }
      expect(response).to have_http_status(:ok)
      expect(json_body["items"].map { |i| i["encounter_id"] }).to eq([ first.id ])
      expect(Urgency::CounterReferrals.for(unit: ubs, now: 59.days.from_now).map { |i| i[:encounter_id] }).to eq([ first.id ])
      expect(Urgency::CounterReferrals.for(unit: ubs, now: 61.days.from_now)).to eq([])
      expect(Urgency::CounterReferrals.for(unit: upa, now: Time.current)).to eq([])

      sign_in_as(nurse)
      get "/urgency/counter_referrals", params: { health_unit_id: ubs.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_link")
      sign_in_as(doctor!(ubs))
      get "/urgency/counter_referrals", params: { health_unit_id: SecureRandom.uuid }
      expect(response).to have_http_status(:not_found)
      get "/urgency/counter_referrals", params: { health_unit_id: ubs.id, name: "x" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(DomainEvent.where(name: "clinical_record.viewed").where("payload->>'resource' = 'encounter'")
                        .where("payload->>'patient_id' = ?", patient.id)).to be_empty
    end
  end
end
