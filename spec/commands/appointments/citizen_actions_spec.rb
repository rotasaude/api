require "rails_helper"

RSpec.describe "Ações do cidadão no horário" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:now) { Time.zone.parse("2026-10-01 10:00") }

  def scheduled_in(delta)
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                  by: doctor).payload.fetch(:appointment_request)
    Appointments::Schedule.call(request: req, scheduled_at: (now + delta).iso8601, health_unit_id: unit.id,
                                by: reception, now: now).payload.fetch(:appointment)
  end

  it "confirma 1s antes do prazo; no prazo exato dá confirmation_closed" do
    appt = scheduled_in(3.days) # prazo = now + 2 dias
    expect(Appointments::Confirm.call(appointment: appt, now: appt.confirmation_deadline_at).reason).to eq(:confirmation_closed)
    expect(Appointments::Confirm.call(appointment: appt, now: appt.confirmation_deadline_at - 1.second)).to be_ok
    expect(appt.reload.status).to eq("confirmed")
    expect(Appointments::Confirm.call(appointment: appt, now: appt.confirmation_deadline_at - 1.second)).to be_ok
  end

  it "cancelar exige motivo; cancela horário e encerra o pedido como citizen_cancelled" do
    appt = scheduled_in(3.days)
    expect(Appointments::CancelByCitizen.call(appointment: appt, reason: "curto").reason).to eq(:reason_too_short)
    r = Appointments::CancelByCitizen.call(appointment: appt, reason: "vou viajar nessa semana")
    expect(r).to be_ok
    expect(appt.reload).to have_attributes(status: "cancelled_by_citizen", cancel_reason: "vou viajar nessa semana")
    expect(appt.request.reload).to have_attributes(status: "closed", closed_reason: "citizen_cancelled")
    expect(Appointments::CancelByCitizen.call(appointment: appt, reason: "de novo, por engano").reason)
      .to eq(:appointment_ended)
  end
end
