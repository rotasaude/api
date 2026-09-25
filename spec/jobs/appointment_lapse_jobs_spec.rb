require "rails_helper"

RSpec.describe "Jobs de expiração e falta" do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  # EachCityJob (perform_now real, como o brief pede) itera City.where(status:
  # "active") na conexão de plataforma; TEST_CITY_A não é persistida lá (é só
  # o objeto do harness). Uma City com o MESMO slug reentra a sessão que o
  # harness já abriu (ver nota 1 em spec/support/city_test_databases.rb).
  let!(:city_record) { create(:city, slug: TEST_CITY_A.slug, database_url: TEST_CITY_A.database_url) }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:t0) { Time.zone.parse("2026-10-01 10:00") }

  def appointment_at(at, now: t0)
    travel_to(now) do
      a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
      req = Attendances::Close.call(attendance: a, outcome: "return", referral_unit_id: nil, referral_note: nil,
                                    by: doctor).payload.fetch(:appointment_request)
      Appointments::Schedule.call(request: req, scheduled_at: at.iso8601, health_unit_id: unit.id, by: reception)
                            .payload.fetch(:appointment)
    end
  end

  it "expira no prazo exato, não 1s antes; pedido volta à fila como expired" do
    appt = appointment_at(t0 + 3.days) # prazo = t0 + 2 dias
    travel_to(appt.confirmation_deadline_at - 1.second) { ExpireUnconfirmedAppointmentsJob.perform_now }
    expect(appt.reload.status).to eq("scheduled")
    travel_to(appt.confirmation_deadline_at) { ExpireUnconfirmedAppointmentsJob.perform_now }
    expect(appt.reload.status).to eq("expired")
    expect(appt.request.reload).to have_attributes(status: "open", reopened_reason: "expired")
    expect(DomainEvent.where(name: "appointment.expired").count).to eq(1)
  end

  it "falta só depois da meia-noite local; pedido volta como no_show" do
    appt = appointment_at(Time.zone.parse("2026-10-01 23:00"), now: Time.zone.parse("2026-10-01 20:00")) # nasce confirmado
    travel_to(Time.zone.parse("2026-10-01 23:59")) { MarkNoShowAppointmentsJob.perform_now }
    expect(appt.reload.status).to eq("confirmed")
    travel_to(Time.zone.parse("2026-10-02 00:01")) { MarkNoShowAppointmentsJob.perform_now }
    expect(appt.reload.status).to eq("no_show")
    expect(appt.request.reload).to have_attributes(status: "open", reopened_reason: "no_show")
  end

  it "rodar duas vezes não muda nada a mais" do
    appt = appointment_at(t0 + 3.days)
    travel_to(appt.confirmation_deadline_at + 1.minute) do
      2.times { ExpireUnconfirmedAppointmentsJob.perform_now }
    end
    expect(DomainEvent.where(name: "appointment.expired").count).to eq(1)
  end

  it "se o cidadão confirmou antes do lock do job, o job não faz nada" do
    appt = appointment_at(t0 + 3.days)
    stale = Appointment.find(appt.id) # visão antiga, ainda scheduled
    Appointments::Confirm.call(appointment: appt, now: appt.confirmation_deadline_at - 1.second)
    travel_to(appt.confirmation_deadline_at + 1.minute) do
      expect(Appointments::Lapse.call(appointment: stale, to: "expired")).to be_ok
    end
    expect(appt.reload.status).to eq("confirmed")
    expect(appt.request.reload.status).to eq("scheduled")
  end
end
