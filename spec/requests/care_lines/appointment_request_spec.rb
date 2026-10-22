require "rails_helper"

# Contrato §11 T4: "Agendar" abre (ou reaproveita) o pedido do módulo 17 na
# unidade da equipe; a fila da unidade mostra o pedido sem triagem raiz.
RSpec.describe "Linhas de cuidado — agendar pela linha", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before { care_city! }

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let!(:team) { care_team!(unit, doctor) }
  let(:patient) { care_patient!(age: 70, sex: "female") }
  let(:pair) { Citizen.find_by!(patient_id: patient.id) }
  let(:enrollment) { care_enrollment!(patient: patient, line: adopted_line!("elderly_c6"), team: team, by: doctor) }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  it "abre o pedido care_line sem triagem raiz na unidade da equipe; a segunda vez devolve o mesmo; só ids no evento" do
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect(response).to have_http_status(:created)
    expect(json_body["request"]).to include("kind" => "care_line", "origin" => "care_line", "target_unit_id" => unit.id,
                                            "triage_priority" => nil, "appointment_type_key" => "retorno",
                                            "cpf_masked" => pair.cpf_masked)
    expect(json_body["unit"]).to include("id" => unit.id, "name" => unit.name, "kind" => unit.kind)
    expect(json_body["can_book"]).to be(false)
    request = AppointmentRequest.sole
    expect(request).to have_attributes(origin_care_line_enrollment_id: enrollment.id, root_triage_id: nil, citizen_id: pair.id,
                                       due_on: Time.zone.today + AppointmentRequest::DUE_IN_DAYS)
    expect(DomainEvent.where(name: "appointment_request.created").sole.payload.keys)
      .to match_array(%w[appointment_request_id care_line_enrollment_id target_unit_id kind user_id])
    expect(DomainEvent.where(name: "clinical_record.viewed")).to be_empty # sem trilha: o item só traz o CPF mascarado
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect(response).to have_http_status(:ok)
    expect(json_body["request"]["id"]).to eq(request.id)
    expect(AppointmentRequest.count).to eq(1)
  end

  it "reaproveita o pedido aberto da pessoa na unidade; só marcado → 409; encerrada → 409; outra equipe → 404" do
    existing = triage_request!(pair, unit: unit)
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body["request"]["id"] ]).to eq([ 200, existing.id ])
    existing.update!(status: "scheduled")
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_scheduled" } ])
    CareLines::EndEnrollment.call(enrollment: enrollment, reason: "moved", note: nil, by: doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "invalid_transition" } ])
    other_unit = care_unit!
    foreign = care_enrollment!(patient: care_patient!(age: 71, sex: "male"), line: adopted_line!("elderly_c6"),
                               team: care_team!(other_unit, care_doctor!(other_unit)), by: doctor)
    json_post "/care_lines/enrollments/#{foreign.id}/appointment_request", {}
    expect(response).to have_http_status(:not_found)
    expect(AppointmentRequest.where(kind: "care_line")).to be_empty
  end

  it "unidade da equipe desativada → 422 invalid_unit, sem pedido" do
    enrollment
    unit.update!(active: false)
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body ]).to eq([ 422, { "error" => "invalid_unit" } ])
    expect(AppointmentRequest.count).to eq(0)
  end

  it "quem marca (citizen_verifier) recebe can_book; a fila da unidade lista o pedido care_line" do
    reception = staff_with("recepcao-#{SecureRandom.hex(3)}@cidade.gov.br", "health_professional", "citizen_verifier")
    link_professional!(reception, unit, cbo: "223505")
    sign_in_as(reception)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect(json_body["can_book"]).to be(true)
    get "/attendance/units/#{unit.id}/requests"
    expect(response).to have_http_status(:ok)
    row = json_body["requests"].find { |r| r["kind"] == "care_line" }
    expect(row).to include("origin" => "care_line", "triage_priority" => nil)
  end

  it "fechar a unidade move o pedido care_line com a origem" do
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    dest = care_unit!
    result = HealthUnits::Drain.call(unit: unit, target_unit_id: dest.id, reason: "unidade fechada para reforma", by: care_admin!)
    expect(result).to be_ok
    moved = AppointmentRequest.find_by!(target_unit_id: dest.id)
    expect(moved).to have_attributes(kind: "care_line", origin_care_line_enrollment_id: enrollment.id, status: "open",
                                     root_triage_id: nil)
  end

  # A cadeia sem triagem raiz: o atendimento do horário da linha não tem raiz;
  # o retorno dele abre um pedido do 17 (kind return) também sem raiz, e a
  # recepção (lookup do check-in e fila) não quebra.
  it "marcado, check-in e retorno: o pedido de retorno nasce sem triagem raiz e entra na fila" do
    travel_to(Time.zone.tomorrow.change(hour: 9)) do
      sign_in_as(doctor)
      json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
      request = AppointmentRequest.find(json_body["request"]["id"])
      appointment = Appointments::Schedule.call(request: request, scheduled_at: Time.zone.now.change(hour: 15).iso8601,
                                                health_unit_id: unit.id, by: reception!).payload.fetch(:appointment)
      code = Citizens::IssueAppointmentCheckInCode.call(citizen: pair, appointment: appointment).payload.fetch(:code)

      sign_in_as(reception!)
      json_post "/attendance/check_ins/lookup", cpf: pair.cpf, code: code, health_unit_id: unit.id
      expect(response).to have_http_status(:ok)
      expect(json_body["appointment"]).to include("id" => appointment.id, "kind" => "care_line", "protocol_name" => nil,
                                                  "priority" => nil)

      attendance = Attendances::CheckIn.call(cpf: pair.cpf, code: code, health_unit_id: unit.id, document_checked: false,
                                             by: reception!).payload.fetch(:attendance)
      expect(attendance).to have_attributes(appointment_id: appointment.id, triage_id: nil)
      expect(attendance.priority).to be_nil
      in_care!(attendance, by: doctor)
      back = Attendances::Close.call(attendance: attendance, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                     by: doctor).payload.fetch(:appointment_request)
      expect(back).to have_attributes(kind: "return", origin_attendance_id: attendance.id, root_triage_id: nil,
                                      origin_care_line_enrollment_id: nil, target_unit_id: unit.id)

      get "/attendance/units/#{unit.id}/requests"
      expect(response).to have_http_status(:ok)
      expect(json_body["requests"].find { |r| r["id"] == back.id }).to include("origin" => "attendance", "triage_priority" => nil)
    end
  end

  it "o banco: care_line exige a inscrição e as unidades; a raiz só falta em care_line ou com origem no atendimento; a origem não muda" do
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    request = AppointmentRequest.sole
    # Encerrado: fora dos índices de "um vivo", só os CHECKs decidem.
    closed = request.attributes.except("id").merge("status" => "closed", "closed_reason" => "fulfilled", "closed_at" => Time.current)
    insert = ->(changes) { attempt { AppointmentRequest.insert_all!([ closed.merge(changes) ]) } }

    triage = completed_web_triage_for(pair)
    expect { insert.call("origin_triage_id" => triage.id) }.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_origin/)
    expect { insert.call("origin_care_line_enrollment_id" => nil) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_care_line/)
    expect { insert.call("kind" => "return") }.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_care_line/)
    expect { insert.call("target_unit_id" => nil) }.to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_care_line/)
    expect { insert.call("kind" => "triage", "origin_care_line_enrollment_id" => nil, "origin_triage_id" => triage.id) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_care_line/)
    expect { insert.call({}) }.not_to raise_error
    other = care_enrollment!(patient: care_patient!(age: 72, sex: "female"), line: adopted_line!("elderly_c6"), team: team, by: doctor)
    expect { attempt { AppointmentRequest.where(id: request.id).update_all(origin_care_line_enrollment_id: other.id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /origin columns never change/)
  end
end
