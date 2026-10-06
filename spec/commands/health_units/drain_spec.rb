require "rails_helper"

# api#29 (F-09.3): esvaziar unidade. O municipal_admin move, de uma vez, os
# pedidos abertos e os horários marcados para outra unidade ativa, com um
# motivo. A unidade de destino do pedido e a unidade do horário não mudam
# (triggers): mover encerra o antigo como `moved` e cria um novo ligado a ele.
# O horário vai com a mesma data e hora; com 48h ou mais, pede nova
# confirmação; com menos, nasce confirmado.
RSpec.describe HealthUnits::Drain do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; link_professional!(doctor, closing) }
  after { Current.reset }

  let(:closing) { create_unit("UBS Fechando") }
  let(:dest) { create_unit("UBS Destino") }
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:now) { Time.zone.parse("2026-10-05 10:00") }
  let(:reason) { "unidade fechada para reforma" }

  def new_request(note: "reavaliar em 15 dias")
    a = in_care!(waiting_attendance(citizen, unit: closing, by: reception), by: doctor)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: note, by: doctor)
                      .payload.fetch(:appointment_request)
  end

  def schedule(req, at)
    Appointments::Schedule.call(request: req, scheduled_at: at.iso8601, health_unit_id: closing.id, by: reception,
                                allow_overlap: true).payload.fetch(:appointment)
  end

  def drain(target: dest, why: reason, by: admin)
    described_class.call(unit: closing, target_unit_id: target.id, reason: why, by: by)
  end

  it "pedido aberto: o antigo fecha como moved e nasce um igual, aberto, na unidade de destino" do
    req, moved = travel_to(now) do
      r = new_request
      [ r, drain.payload ]
    end
    expect(moved).to include(requests: 1, appointments: 0)
    expect(req.reload).to have_attributes(status: "closed", closed_reason: "moved")
    fresh = AppointmentRequest.find_by!(moved_from_request_id: req.id)
    expect(fresh).to have_attributes(status: "open", target_unit_id: dest.id, origin_unit_id: closing.id,
                                     kind: "return", note: "reavaliar em 15 dias", citizen_id: citizen.id,
                                     origin_attendance_id: req.origin_attendance_id, root_triage_id: req.root_triage_id)
  end

  it "horário a 48h ou mais: mesma data e hora na nova unidade, pedindo nova confirmação" do
    appt = travel_to(now) do
      a = schedule(new_request, now + 5.days)
      Appointments::Confirm.call(appointment: a, now: now)
      a
    end
    travel_to(now + 1.hour) { drain }

    expect(appt.reload).to have_attributes(status: "moved")
    expect(appt.ended_at).to be_present
    moved = Appointment.find_by!(moved_from_appointment_id: appt.id)
    expect(moved).to have_attributes(health_unit_id: dest.id, scheduled_at: appt.scheduled_at, status: "scheduled",
                                     confirmation_deadline_at: appt.scheduled_at - 24.hours)
    expect(moved.request).to have_attributes(status: "scheduled", target_unit_id: dest.id,
                                             moved_from_request_id: appt.request_id)
  end

  it "horário a menos de 48h: vai confirmado" do
    appt = travel_to(now) { schedule(new_request, now + 30.hours) }
    travel_to(now + 1.hour) { drain }
    expect(Appointment.find_by!(moved_from_appointment_id: appt.id)).to have_attributes(status: "confirmed")
  end

  it "horário ocupado no destino vai como encaixe" do
    travel_to(now) do
      # Outro cidadão: o mesmo cidadão no mesmo instante seria citizen_busy (ADR 0029).
      someone = Citizen.create!(cpf: "11144477735", phone: "+5541911112222")
      other = Attendances::Close.call(
        attendance: in_care!(waiting_attendance(someone, unit: closing, by: reception), by: doctor),
        outcome: "referred", referral_unit_id: dest.id, referral_note: nil, by: doctor
      ).payload.fetch(:appointment_request)
      Appointments::Schedule.call(request: other, scheduled_at: (now + 5.days).iso8601, health_unit_id: dest.id,
                                  by: reception)
      schedule(new_request, now + 5.days)
      expect(drain).to be_ok
    end
    payload = DomainEvent.where(name: "appointment.moved").last.payload
    expect(payload).to include("fit_in" => true)
  end

  it "deixa a unidade pronta para desativar e registra o esvaziamento com o motivo" do
    travel_to(now) do
      schedule(new_request, now + 5.days)
      new_request
      expect(AppointmentRequest.live_requests.where(target_unit: closing).count).to eq(2)
      expect(drain).to be_ok
      expect(AppointmentRequest.live_requests.where(target_unit: closing)).to be_empty
    end
    record = HealthUnitDrain.last
    expect(record).to have_attributes(health_unit_id: closing.id, target_unit_id: dest.id, reason: reason,
                                      requests_count: 2, appointments_count: 1, drained_by_user_id: admin.id)
    event = DomainEvent.find_by!(name: "health_unit.drained").payload
    expect(event.keys).to match_array(%w[health_unit_drain_id health_unit_id target_unit_id requests_count
                                         appointments_count])
  end

  it "recusa destino igual, inativo ou de fora, e motivo curto, sem mexer em nada" do
    travel_to(now) do
      req = new_request
      inactive = create_unit("UBS Desativada")
      inactive.update!(active: false)
      expect(drain(target: closing).reason).to eq(:invalid_target)
      expect(drain(target: inactive).reason).to eq(:invalid_target)
      expect(described_class.call(unit: closing, target_unit_id: SecureRandom.uuid, reason: reason, by: admin).reason)
        .to eq(:invalid_target)
      expect(drain(why: "curto").reason).to eq(:reason_too_short)
      expect(req.reload.status).to eq("open")
      expect(HealthUnitDrain.count).to eq(0)
    end
  end

  it "nenhum evento do esvaziamento carrega o motivo, a nota, o CPF ou o celular" do
    travel_to(now) do
      schedule(new_request, now + 5.days)
      drain
    end
    secrets = [ reason, "reavaliar em 15 dias", citizen.cpf, citizen.phone ]
    DomainEvent.where(name: %w[health_unit.drained appointment_request.moved appointment.moved]).find_each do |e|
      secrets.each { |s| expect(e.payload.to_json).not_to include(s) }
    end
    expect(DomainEvent.where(name: "appointment_request.moved").count).to eq(1)
  end

  it "o banco recusa mudar ou apagar o registro do esvaziamento e mover sem ligação" do
    travel_to(now) { new_request; drain }
    record = HealthUnitDrain.last
    attempt = ->(&b) { ApplicationRecord.transaction(requires_new: true, &b) }
    expect { attempt.call { HealthUnitDrain.where(id: record.id).update_all(reason: "outro motivo qualquer") } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { attempt.call { HealthUnitDrain.where(id: record.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "o pedido movido mantém o lugar na fila (mesmo created_at)" do
    req = travel_to(now) { new_request }
    travel_to(now + 3.days) { drain }
    fresh = AppointmentRequest.find_by!(moved_from_request_id: req.id)
    expect(fresh.created_at).to eq(req.created_at)
  end

  it "horário com prazo já vencido segue o caminho normal antes: expira e o pedido vai aberto" do
    appt = travel_to(now) { schedule(new_request, now + 5.days) } # prazo: now + 4 dias
    travel_to(now + 4.days + 1.hour) do # prazo vencido, job ainda não rodou
      expect(drain.payload).to include(requests: 1, appointments: 0)
    end
    expect(appt.reload.status).to eq("expired")
    fresh = AppointmentRequest.find_by!(moved_from_request_id: appt.request_id)
    expect(fresh).to have_attributes(status: "open", reopened_reason: "expired", target_unit_id: dest.id)
    expect(Appointment.where(moved_from_appointment_id: appt.id)).to be_empty
  end

  it "trava o horário no destino antes de conferir o encaixe" do
    travel_to(now) do
      appt = schedule(new_request, now + 5.days)
      expect(Appointments::Schedule).to receive(:lock_slot!).with(dest.id, appt.scheduled_at).and_call_original
      drain
    end
  end
  it "pedido de triagem movido leva tipo, prioridade, prazo, origem e as triagens ligadas (ADR 0029)" do
    ensure_appointment_types!
    req = triage_request!(Citizen.create!(cpf: "39053344705", phone: "+5541933334444"), unit: closing,
                          priority: "priority", due_on: Time.zone.today + 9)
    extra = completed_web_triage_for(req.citizen)
    AppointmentRequestTriage.create!(request: req, triage: extra, created_at: Time.current)
    HealthUnits::Drain.call(unit: closing, target_unit_id: dest.id, reason: "reforma da unidade", by: admin)
    fresh = AppointmentRequest.find_by!(moved_from_request_id: req.id)
    expect(fresh).to have_attributes(kind: "triage", origin_triage_id: req.origin_triage_id, origin_attendance_id: nil,
                                     origin_unit_id: nil, priority: "priority", due_on: Time.zone.today + 9,
                                     appointment_type_key: "consulta_medica", target_unit_id: dest.id, status: "open")
    expect(fresh.request_triages.pluck(:triage_id)).to eq([ extra.id ])
  end

  it "pedido de retorno movido leva tipo, prioridade, prazo e os dados da remarcação" do
    req = travel_to(now) { new_request }
    req.update_columns(priority: "priority", due_on: Date.new(2026, 10, 20), preferred_period: "morning",
                       reschedule_reason_code: "work", reschedule_note: "trabalho de manhã", reschedule_count: 1)
    travel_to(now + 1.hour) { drain }
    fresh = AppointmentRequest.find_by!(moved_from_request_id: req.id)
    expect(fresh).to have_attributes(appointment_type_key: "retorno", priority: "priority",
                                     due_on: Date.new(2026, 10, 20), preferred_period: "morning",
                                     reschedule_reason_code: "work", reschedule_note: "trabalho de manhã",
                                     reschedule_count: 1)
  end
end
