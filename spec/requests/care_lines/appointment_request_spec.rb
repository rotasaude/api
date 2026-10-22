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
    expect(json_body["request"]).to include("kind" => "triage", "origin" => "triage") # o tipo real do reaproveitado
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

    # "Agendar" de novo: o pedido da inscrição vive na unidade de destino (nunca 500).
    unit.update!(active: false)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body["request"]["id"], json_body["unit"]["id"] ]).to eq([ 200, moved.id, dest.id ])
    moved.update!(status: "scheduled")
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_scheduled" } ])
    expect(AppointmentRequest.where(kind: "care_line").live_requests.count).to eq(1)
  end

  it "par excluído ou rebaixado → 409 citizen_not_verified, sem pedido" do
    enrollment
    sign_in_as(doctor)
    pair.update!(verification_level: "declared")
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
    pair.update!(verification_level: "verified")
    pair.update_columns(erased_at: Time.current)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "citizen_not_verified" } ])
    expect(AppointmentRequest.count).to eq(0)
  end

  it "com dois pares validados, o pedido da linha nasce com o mais antigo e é reaproveitado depois que esse par é rebaixado" do
    enrollment
    # Determinístico: o par mais antigo tem o MAIOR id possível (order(:id) o
    # deixaria por último; pairs.first escolheria o outro sempre).
    oldest = Citizen.create!(id: "ffffffff-ffff-4fff-bfff-ffffffffffff", cpf: pair.cpf, phone: "+5541977776666",
                             birth_date: birth_date_for(70), sex: "female", profile_source: "declared",
                             created_at: pair.created_at - 1.year)
    CitizenVerification.create!(citizen: oldest, verified_by_user: verifier!, verified_at: Time.current)
    oldest.update!(verification_level: "verified", profile_source: "verified", full_name: "Maria Aparecida da Silva",
                   mother_name: "Joana da Silva")
    oldest.update_columns(patient_id: patient.id)
    expect(oldest.id).to be > pair.id
    expect(oldest.created_at).to be < pair.created_at
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect(response).to have_http_status(:created)
    request = AppointmentRequest.sole
    expect(request.citizen_id).to eq(oldest.id) # o par mais antigo, não o menor UUID

    oldest.update!(verification_level: "declared")
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body["request"]["id"], json_body["unit"]["id"] ]).to eq([ 200, request.id, unit.id ])
    expect(AppointmentRequest.count).to eq(1)
  end

  it "pedido da linha marcado na unidade da equipe e outro aberto ali: 409 already_scheduled, sem reaproveitar nem criar" do
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    own = AppointmentRequest.find(json_body["request"]["id"])
    Appointments::Schedule.call(request: own, scheduled_at: 5.days.from_now.change(hour: 10).iso8601, health_unit_id: unit.id,
                                by: reception!).payload.fetch(:appointment)
    expect(own.reload.status).to eq("scheduled")
    triage_request!(pair, unit: unit)
    expect { json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {} }
      .not_to change(AppointmentRequest, :count)
    expect([ response.status, json_body ]).to eq([ 409, { "error" => "already_scheduled" } ])
  end

  it "reaproveitando um encaminhamento com nota, a resposta não traz a nota livre" do
    other_unit = care_unit!
    attendance = walk_in_attendance!(other_unit, citizen: pair)
    referral = AppointmentRequest.create!(origin_attendance: attendance, citizen: pair, root_triage: attendance.root_triage,
                                          origin_unit: other_unit, target_unit: unit, kind: "referral",
                                          note: "nota livre do encaminhamento")
    sign_in_as(doctor)
    json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
    expect([ response.status, json_body["request"]["id"] ]).to eq([ 200, referral.id ])
    expect(json_body["request"]).not_to have_key("note")
    expect(response.body).not_to include("nota livre")
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

      # A cópia do Drain do retorno sem raiz passa pela guarda da cadeia.
      dest = care_unit!
      expect(HealthUnits::Drain.call(unit: unit, target_unit_id: dest.id, reason: "unidade fechada para reforma", by: care_admin!)).to be_ok
      expect(AppointmentRequest.live_requests.find_by!(moved_from_request_id: back.id))
        .to have_attributes(kind: "return", root_triage_id: nil, origin_attendance_id: attendance.id, target_unit_id: dest.id)
    end
  end

  # rota_appointment_request_root_guard: raiz nula com origem num atendimento
  # só quando a cadeia do atendimento também não tem raiz.
  it "o banco recusa pedido sem raiz de atendimento que tem raiz (triagem ou horário de pedido com raiz)" do
    from_triage = walk_in_attendance!(unit, citizen: pair)
    expect do
      attempt { AppointmentRequest.create!(origin_attendance: from_triage, citizen: pair, root_triage: nil, origin_unit: unit, target_unit: unit, kind: "return") }
    end.to raise_error(ActiveRecord::StatementInvalid, /the attendance chain has a root triage/)
    from_appointment = scheduled_attendance!(unit, citizen: pair)
    expect do
      attempt { AppointmentRequest.create!(origin_attendance: from_appointment, citizen: pair, root_triage: nil, origin_unit: unit, target_unit: unit, kind: "return") }
    end.to raise_error(ActiveRecord::StatementInvalid, /the attendance chain has a root triage/)
    expect { AppointmentRequest.create!(origin_attendance: from_triage, citizen: pair, root_triage: from_triage.root_triage, origin_unit: unit, target_unit: unit, kind: "return") }
      .not_to raise_error
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

  # M4: encerrar por óbito ou mudança fecha o pedido care_line vivo da própria
  # inscrição (dismissed, texto fixo), cancelando o horário vivo como a
  # exclusão LGPD faz; os outros motivos e o pedido reaproveitado ficam.
  describe "encerrar a inscrição" do
    def open_by_line!
      sign_in_as(doctor)
      json_post "/care_lines/enrollments/#{enrollment.id}/appointment_request", {}
      AppointmentRequest.find(json_body["request"]["id"])
    end

    def end_enrollment!(reason)
      result = CareLines::EndEnrollment.call(enrollment: enrollment, reason: reason, note: nil, by: doctor)
      expect(result).to be_ok
    end

    it "óbito fecha o pedido aberto como dismissed, com o texto do motivo; o evento do 17 só com ids" do
      request = open_by_line!
      end_enrollment!("death")
      expect(request.reload).to have_attributes(status: "closed", closed_reason: "dismissed", closed_by_user_id: doctor.id,
                                                dismiss_reason: CareLines::EndEnrollment::REQUEST_DISMISS_REASONS.fetch("death"))
      expect(DomainEvent.where(name: "appointment_request.closed").sole.payload)
        .to eq("appointment_request_id" => request.id, "closed_reason" => "dismissed")
    end

    it "mudança fecha o pedido marcado e cancela o horário vivo pelo caminho do 17" do
      request = open_by_line!
      appointment = Appointments::Schedule.call(request: request, scheduled_at: 5.days.from_now.change(hour: 10).iso8601,
                                                health_unit_id: unit.id, by: reception!).payload.fetch(:appointment)
      expect(request.reload.status).to eq("scheduled")
      end_enrollment!("moved")
      expect(appointment.reload).to have_attributes(status: "cancelled_by_citizen", cancel_reason: CareLines::EndEnrollment::APPOINTMENT_CANCEL_REASON)
      expect(appointment.ended_at).to be_present
      expect(request.reload).to have_attributes(status: "closed", closed_reason: "dismissed",
                                                dismiss_reason: CareLines::EndEnrollment::REQUEST_DISMISS_REASONS.fetch("moved"))
      expect(DomainEvent.where(name: "appointment.cancelled").sole.payload).to eq("appointment_id" => appointment.id, "by" => "care_line")
      expect(DomainEvent.where(name: "appointment_request.closed").sole.payload)
        .to eq("appointment_request_id" => request.id, "closed_reason" => "dismissed")
    end

    it "pedido fechado entre a releitura e a trava (Dismiss): o óbito encerra a inscrição sem erro" do
      request = open_by_line!
      stale = AppointmentRequest.find(request.id) # ainda "open" em memória
      expect(AppointmentRequests::Dismiss.call(request: request, reason: "cidadão não quer remarcar", health_unit_id: unit.id,
                                               by: reception!)).to be_ok
      allow(CareLines::EndEnrollment).to receive(:own_live_request).and_return(stale)
      end_enrollment!("death")
      expect(enrollment.reload).to have_attributes(status: "ended", ended_reason: "death")
      expect(request.reload).to have_attributes(status: "closed", closed_reason: "dismissed", dismiss_reason: "cidadão não quer remarcar")
      expect(DomainEvent.where(name: "appointment_request.closed").count).to eq(1)
    end

    it "alta (e os outros motivos) não fecha o pedido" do
      request = open_by_line!
      end_enrollment!("discharge")
      expect(request.reload.status).to eq("open")
      expect(DomainEvent.where(name: "appointment_request.closed")).to be_empty
    end

    it "óbito não fecha o pedido reaproveitado de outro tipo" do
      existing = triage_request!(pair, unit: unit)
      expect(open_by_line!.id).to eq(existing.id)
      end_enrollment!("death")
      expect(existing.reload.status).to eq("open")
      expect(AppointmentRequest.where(kind: "care_line")).to be_empty
    end

    it "óbito fecha também o pedido da inscrição movido por um Drain" do
      open_by_line!
      dest = care_unit!
      expect(HealthUnits::Drain.call(unit: unit, target_unit_id: dest.id, reason: "unidade fechada para reforma", by: care_admin!)).to be_ok
      end_enrollment!("death")
      expect(AppointmentRequest.where(origin_care_line_enrollment_id: enrollment.id).live_requests).to be_empty
      expect(AppointmentRequest.find_by!(target_unit_id: dest.id)).to have_attributes(status: "closed", closed_reason: "dismissed")
    end
  end
end
