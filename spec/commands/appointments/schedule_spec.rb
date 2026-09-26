require "rails_helper"

RSpec.describe Appointments::Schedule do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:now) { Time.zone.parse("2026-10-01 10:00") }
  let(:req) do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil, by: doctor)
                      .payload.fetch(:appointment_request)
  end

  def schedule(at)
    described_class.call(request: req, scheduled_at: at.iso8601, health_unit_id: unit.id, by: reception, now: now)
  end

  it "com 48h exatas: scheduled com prazo 24h antes" do
    appt = schedule(now + 48.hours).payload[:appointment]
    expect(appt).to have_attributes(status: "scheduled", confirmation_deadline_at: now + 24.hours)
    expect(req.reload).to have_attributes(status: "scheduled", reopened_reason: nil)
  end

  it "com 48h menos 1s: nasce confirmado, sem prazo" do
    appt = schedule(now + 48.hours - 1.second).payload[:appointment]
    expect(appt).to have_attributes(status: "confirmed", confirmation_deadline_at: nil)
    expect(appt.confirmed_at).to be_present
  end

  it "passado, agora e mais de 180 dias: invalid_time" do
    expect(schedule(now - 1.minute).reason).to eq(:invalid_time)
    expect(schedule(now).reason).to eq(:invalid_time)
    expect(schedule(now + 180.days + 1.second).reason).to eq(:invalid_time)
    expect(described_class.call(request: req, scheduled_at: "amanhã", health_unit_id: unit.id, by: reception, now: now)
                          .reason).to eq(:invalid_time)
  end

  it "pedido já agendado: request_not_open" do
    schedule(now + 3.days)
    expect(schedule(now + 4.days).reason).to eq(:request_not_open)
  end

  it "outra unidade: wrong_unit; unidade de destino desativada: invalid_unit" do
    other = create_unit("UPA Norte", kind: "upa")
    expect(described_class.call(request: req, scheduled_at: (now + 3.days).iso8601, health_unit_id: other.id,
                                by: reception, now: now).reason).to eq(:wrong_unit)
    req.target_unit.update!(active: false)
    expect(schedule(now + 3.days).reason).to eq(:invalid_unit)
  end
end
