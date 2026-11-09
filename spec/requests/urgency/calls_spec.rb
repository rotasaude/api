require "rails_helper"

# Módulo 32a (ADR 0050; contrato §6 e §14 Q6, Q7, Q15; plano, Desvios 11 e
# 12): a fila por cor, o "chamar próximo" da UPA, a chamada do médico pelo
# Attendances::Call do 13, a chamada para a classificação, o local da chamada
# e o "chamar de novo". Com o waiting_room_display desligado, nada de
# attendance_calls e o local é ignorado.
RSpec.describe "Chamadas da urgência", type: :request do
  let(:upa) { upa! }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  before { urgency_protocol! }
  after { Current.reset }

  def call_next(unit = upa, **body) = json_post("/attendance/units/#{unit.id}/call_next", body)
  def call(attendance, **body) = json_post("/attendance/attendances/#{attendance.id}/call", { health_unit_id: attendance.health_unit_id, **body })
  def call_for_classification(encounter, **body) = json_post("/urgency/encounters/#{encounter.id}/call_for_classification", body)
  def recall(attendance, **body) = json_post("/attendance/attendances/#{attendance.id}/recall", body)

  context "sem a sala de espera" do
    let!(:city) { urgency_city! }

    it "\"chamar próximo\" só com não classificados → 404 queue_empty; o médico chama o primeiro por cor e o encontro vai a in_care" do
      waiting = arrived!(upa, patient: urgency_patient!(1))
      sign_in_as(doctor)
      call_next
      expect(response).to have_http_status(:not_found)
      expect(json_body["error"]).to eq("queue_empty")
      expect(waiting.attendance.reload.status).to eq("waiting")

      green = classified!(arrived!(upa, patient: urgency_patient!(2)), color: "green", by: nurse)
      red = classified!(arrived!(upa, patient: urgency_patient!(3)), color: "red", by: nurse)
      call_next(call_location_id: SecureRandom.uuid)
      expect(response).to have_http_status(:ok)
      expect(json_body.dig("attendance", "id")).to eq(red.attendance_id)
      expect(red.reload.state).to eq("in_care")
      expect(red.attendance.status).to eq("in_care")
      expect(green.reload.state).to eq("classified")
      expect(AttendanceCall.count).to eq(0)
    end

    it "atendimento do check-in do 13 na UPA (antes de ligar a urgência): o \"chamar próximo\" cai nele sem classificado; só não classificados → 404" do
      unclassified = arrived!(upa, patient: urgency_patient!(21))
      legacy = waiting_attendance(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: upa, by: upa_reception!)
      classified = classified!(arrived!(upa, patient: urgency_patient!(22)), color: "blue", by: nurse)
      sign_in_as(doctor)
      call_next
      expect(json_body.dig("attendance", "id")).to eq(classified.attendance_id)
      call_next
      expect(response).to have_http_status(:ok)
      expect(json_body.dig("attendance", "id")).to eq(legacy.id)
      call_next
      expect(response).to have_http_status(:not_found)
      expect(json_body["error"]).to eq("queue_empty")
      expect(unclassified.attendance.reload.status).to eq("waiting")
    end

    it "Call de não classificado → 422 not_classified; a enfermagem chamando para o atendimento → 403 cbo_not_allowed" do
      encounter = arrived!(upa, patient: urgency_patient!(4))
      sign_in_as(doctor)
      call(encounter.attendance)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("not_classified")
      classified!(encounter, color: "yellow", by: nurse)
      sign_in_as(nurse)
      call(encounter.attendance)
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("cbo_not_allowed")
      call_next
      expect(json_body["error"]).to eq("cbo_not_allowed")
      expect(encounter.reload.state).to eq("classified")
      sign_in_as(doctor)
      call(encounter.attendance, call_location_id: "nao-e-uuid")
      expect(response).to have_http_status(:ok)
      expect(encounter.reload.state).to eq("in_care")
    end

    it "chamada para a classificação sem sala de espera: call nulo, sem linha, o atendimento segue aguardando" do
      encounter = arrived!(upa, patient: urgency_patient!(5))
      sign_in_as(nurse)
      call_for_classification(encounter, call_location_id: SecureRandom.uuid)
      expect(response).to have_http_status(:ok)
      expect(json_body["call"]).to be_nil
      expect(json_body.dig("encounter", "id")).to eq(encounter.id)
      expect(AttendanceCall.count).to eq(0)
      expect(encounter.attendance.reload.status).to eq("waiting")
    end

    it "\"chamar de novo\" sem a sala de espera → 403 feature_disabled" do
      encounter = arrived!(upa, patient: urgency_patient!(6))
      sign_in_as(nurse)
      recall(encounter.attendance)
      expect(response).to have_http_status(:forbidden)
      expect(json_body).to eq("error" => "feature_disabled", "feature" => "waiting_room_display")
    end

    it "fila: três grupos, só ids e a pessoa, sem trilha; a recepção lê; quem não é da UPA não" do
      waiting = arrived!(upa, patient: urgency_patient!(7))
      classified = classified!(arrived!(upa, patient: urgency_patient!(8)), color: "orange", by: nurse)
      sign_in_as(upa_reception!)
      expect { get "/urgency/queue", params: { health_unit_id: upa.id } }
        .not_to(change { DomainEvent.where(name: "clinical_record.viewed").count })
      expect(response).to have_http_status(:ok)
      expect(json_body.keys).to contain_exactly("awaiting_classification", "by_color", "in_care")
      expect(json_body["awaiting_classification"].first).to include("encounter_id" => waiting.id, "attendance_id" => waiting.attendance_id,
                                                                    "last_call" => nil)
      expect(json_body["by_color"].first).to include("encounter_id" => classified.id, "color" => "orange", "overdue" => false,
                                                     "max_wait_minutes" => 10)
      expect(response.body).not_to include(UrgencyHelpers::COMPLAINT)
      expect(response.body).not_to include(UrgencyHelpers::JUSTIFICATION)

      sign_in_as(nurse)
      get "/urgency/queue", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:ok)
      get "/urgency/queue", params: { health_unit_id: upa.id, cpf: "1" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["path"]).to eq("cpf")
      sign_in_as(upa_nurse!(upa!))
      get "/urgency/queue", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("missing_link")
      sign_in_as(upa_nurse!(upa, cbo: "322205"))
      get "/urgency/queue", params: { health_unit_id: upa.id }
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("cbo_not_allowed")
      get "/urgency/queue", params: { health_unit_id: SecureRandom.uuid }
      expect(response).to have_http_status(:not_found)
      get "/urgency/queue", params: { health_unit_id: create_unit.id }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("not_an_upa")
    end
  end

  context "com o urgency_care desligado e walk_ins esperando" do
    let!(:city) { urgency_city! }

    it "o \"chamar próximo\" do 13 nunca trava num walk_in: chama o atendimento do 13 que chegou depois" do
      unclassified = arrived!(upa, patient: urgency_patient!(31))
      classified = classified!(arrived!(upa, patient: urgency_patient!(32)), color: "red", by: nurse)
      Platform::Features.set!(city: city, key: Urgency::Gate::KEY, enabled: false, maintainer: ledi_maintainer!)
      CityCatalog.reset_cache!
      later = waiting_attendance(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: upa, by: upa_reception!)
      # Sem prioridade, o do 13 empata com os walk_ins e vem depois deles pela chegada.
      later.triage.update_columns(priority: nil)
      expect(later.checked_in_at).to be > classified.attendance.checked_in_at
      sign_in_as(doctor)
      call_next
      expect(response).to have_http_status(:ok)
      expect(json_body.dig("attendance", "id")).to eq(later.id)
      call_next
      expect(json_body["error"]).to eq("queue_empty")
      expect([ unclassified, classified ].map { |e| e.attendance.reload.status }).to eq(%w[waiting waiting])
    end
  end

  context "com a sala de espera" do
    let!(:city) { urgency_city!(waiting_room: true) }
    let(:office) { call_location!(upa, name: "Consultório 1") }

    it "sem TV pareada o local é opcional; com TV, call_next exige local da unidade, ativo, e grava a chamada care com a senha" do
      encounter = classified!(arrived!(upa, patient: urgency_patient!(11)), color: "yellow", by: nurse)
      paired_display_row!(upa)
      sign_in_as(doctor)
      call_next
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("call_location_required")
      call_next(call_location_id: call_location!(upa!, name: "Consultório 9").id)
      expect(json_body["error"]).to eq("invalid_call_location")
      call_next(call_location_id: CallLocation.create!(health_unit: upa, name: "Antigo", active: false, updated_by_user: urgency_admin!).id)
      expect(json_body["error"]).to eq("invalid_call_location")
      expect(encounter.reload.state).to eq("classified")
      expect(AttendanceCall.count).to eq(0)

      call_next(call_location_id: office.id)
      expect(response).to have_http_status(:ok)
      row = AttendanceCall.sole
      expect(row).to have_attributes(attendance_id: encounter.attendance_id, ticket: encounter.attendance.ticket, kind: "care",
                                     call_location_id: office.id, called_by_user_id: doctor.id)
      expect(row.ticket).to match(/\AU-\d{3}\z/)
      expect(encounter.reload.state).to eq("in_care")
    end

    it "sem TV pareada, Call sem local grava a chamada sem local" do
      encounter = classified!(arrived!(upa, patient: urgency_patient!(12)), color: "green", by: nurse)
      WaitingRoomDisplay.create!(health_unit: upa, name: "TV sem parear", created_by_user: urgency_admin!)
      sign_in_as(doctor)
      call(encounter.attendance)
      expect(response).to have_http_status(:ok)
      expect(AttendanceCall.sole).to have_attributes(kind: "care", call_location_id: nil)
    end

    it "chamada para a classificação grava kind classification, o atendimento segue aguardando; 3222 → 403; fechado → 409" do
      encounter = arrived!(upa, patient: urgency_patient!(13))
      paired_display_row!(upa)
      room = call_location!(upa, name: "Classificação")
      sign_in_as(nurse)
      call_for_classification(encounter)
      expect(json_body["error"]).to eq("call_location_required")
      call_for_classification(encounter, call_location_id: room.id, note: "x")
      expect(json_body).to include("error" => "invalid_request", "path" => "note")
      expect { call_for_classification(encounter, call_location_id: room.id) }
        .to change { DomainEvent.where(name: "clinical_record.viewed").count }.by(1)
      expect(response).to have_http_status(:ok)
      row = AttendanceCall.sole
      expect(row).to have_attributes(kind: "classification", call_location_id: room.id, ticket: encounter.attendance.ticket)
      expect(json_body["call"]).to eq("id" => row.id, "kind" => "classification", "ticket" => row.ticket, "location" => "Classificação",
                                      "called_at" => row.called_at.iso8601)
      expect(json_body.dig("encounter", "state")).to eq("waiting_classification")
      expect(encounter.attendance.reload.status).to eq("waiting")

      sign_in_as(upa_nurse!(upa, cbo: "322205"))
      call_for_classification(encounter, call_location_id: room.id)
      expect(response).to have_http_status(:forbidden)
      expect(json_body["error"]).to eq("cbo_not_allowed")

      Attendances::Close.call(attendance: encounter.attendance, outcome: "left", referral_unit_id: nil, referral_note: nil, by: upa_reception!)
      sign_in_as(nurse)
      call_for_classification(encounter, call_location_id: room.id)
      expect(response).to have_http_status(:conflict)
      expect(json_body["error"]).to eq("encounter_closed")
      expect(AttendanceCall.count).to eq(1)
    end

    it "\"chamar de novo\" grava outra chamada do mesmo tipo sem mudar o estado; sem chamada anterior → 422 not_called" do
      encounter = arrived!(upa, patient: urgency_patient!(14))
      room = call_location!(upa, name: "Classificação")
      sign_in_as(nurse)
      recall(encounter.attendance, call_location_id: room.id)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_body["error"]).to eq("not_called")

      call_for_classification(encounter, call_location_id: room.id)
      expect { recall(encounter.attendance, call_location_id: room.id) }
        .to change { DomainEvent.where(name: "attendance.recalled").count }.by(1)
      expect(response).to have_http_status(:created)
      again = AttendanceCall.order(:called_at, :id).last
      expect(json_body).to eq("call_id" => again.id, "call" => { "id" => again.id, "kind" => "classification", "ticket" => again.ticket,
                                                                  "location" => "Classificação", "called_at" => again.called_at.iso8601 })
      expect(AttendanceCall.where(attendance_id: encounter.attendance_id).pluck(:kind)).to eq(%w[classification classification])
      expect(DomainEvent.where(name: "attendance.recalled").last.payload)
        .to eq("attendance_id" => encounter.attendance_id, "call_id" => again.id)
      expect(encounter.reload.state).to eq("waiting_classification")
      expect(encounter.attendance.reload.status).to eq("waiting")

      classified!(encounter, color: "green", by: nurse)
      called!(encounter, by: doctor, call_location: office)
      sign_in_as(doctor)
      recall(encounter.attendance, call_location_id: office.id)
      expect(AttendanceCall.order(:called_at, :id).last).to have_attributes(kind: "care", call_location_id: office.id)
      expect(encounter.reload.state).to eq("in_care")

      sign_in_as(upa_reception!)
      recall(encounter.attendance, call_location_id: office.id)
      expect(response).to have_http_status(:forbidden)
    end

    it "na UBS com TV, o Call do 13 também exige o local e grava a chamada" do
      ubs = create_unit("UBS Centro")
      ubs_doctor = staff_with("medica-ubs@cidade.gov.br", "health_professional").tap { |u| link_professional!(u, ubs) }
      attendance = waiting_attendance(Citizen.create!(cpf: "52998224725", phone: "+5541998765432"), unit: ubs, by: upa_reception!)
      paired_display_row!(ubs)
      desk = call_location!(ubs, name: "Consultório 3")
      sign_in_as(ubs_doctor)
      call(attendance)
      expect(json_body["error"]).to eq("call_location_required")
      call(attendance, call_location_id: office.id)
      expect(json_body["error"]).to eq("invalid_call_location")
      call(attendance, call_location_id: desk.id)
      expect(response).to have_http_status(:ok)
      expect(attendance.reload.status).to eq("in_care")
      expect(AttendanceCall.sole).to have_attributes(attendance_id: attendance.id, kind: "care", call_location_id: desk.id)
    end
  end
end
