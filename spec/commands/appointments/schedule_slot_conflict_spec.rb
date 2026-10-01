require "rails_helper"

# api#26: dois cidadãos no mesmo horário da unidade. O horário não tem
# profissional nem duração, então "mesmo horário" é mesma unidade e mesmo
# início. A recepção é avisada (slot_taken) e pode marcar mesmo assim
# (allow_overlap), para um encaixe consciente numa unidade com vários
# profissionais.
RSpec.describe "Appointments::Schedule — conflito de horário" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A; link_professional!(doctor, unit) }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:now) { Time.zone.parse("2026-10-01 10:00") }
  let(:slot) { Time.zone.parse("2026-10-06 14:00") }

  def new_request
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil, by: doctor)
                      .payload.fetch(:appointment_request)
  end

  def schedule(req, at, **opts)
    Appointments::Schedule.call(request: req, scheduled_at: at.iso8601, health_unit_id: unit.id, by: reception,
                                now: now, **opts)
  end

  it "horário já ocupado na unidade: slot_taken com quantos, e o pedido segue aberto" do
    expect(schedule(new_request, slot)).to be_ok
    second = new_request
    r = schedule(second, slot)
    expect(r.reason).to eq(:slot_taken)
    expect(r.details).to eq(taken: 1)
    expect(second.reload.status).to eq("open")
    expect(Appointment.where(health_unit_id: unit.id, scheduled_at: slot).count).to eq(1)
  end

  it "com allow_overlap marca o encaixe e o evento registra fit_in" do
    expect(schedule(new_request, slot)).to be_ok
    r = schedule(new_request, slot, allow_overlap: true)
    expect(r).to be_ok
    expect(Appointment.where(health_unit_id: unit.id, scheduled_at: slot).count).to eq(2)
    payloads = DomainEvent.where(name: "appointment.scheduled").order(:occurred_at).map(&:payload)
    expect(payloads.map { |p| p["fit_in"] }).to eq([ false, true ])
  end

  it "outro minuto não conflita" do
    expect(schedule(new_request, slot)).to be_ok
    expect(schedule(new_request, slot + 1.minute)).to be_ok
  end

  it "horário cancelado, expirado ou com falta libera o lugar" do
    cancelled = schedule(new_request, slot).payload.fetch(:appointment)
    Appointments::CancelByCitizen.call(appointment: cancelled, reason: "não consigo ir nesse dia")
    expect(schedule(new_request, slot)).to be_ok

    late = Time.zone.parse("2026-10-07 09:00")
    expired = schedule(new_request, late).payload.fetch(:appointment)
    Appointments::Lapse.call(appointment: expired, to: "expired", now: expired.confirmation_deadline_at)
    expect(schedule(new_request, late)).to be_ok
  end

  it "trava unidade + início antes de contar os horários vivos" do
    expect(Appointments::Schedule).to receive(:lock_slot!).with(unit.id, slot).ordered.and_call_original
    expect(Appointment).to receive(:where).ordered.and_call_original
    schedule(new_request, slot)
  end
end
