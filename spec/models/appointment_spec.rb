require "rails_helper"

RSpec.describe Appointment do
  include ActiveSupport::Testing::TimeHelpers
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:req) do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    a.update!(status: "closed", outcome: "return", closed_by_user: doctor, closed_at: Time.current)
    request_for(a)
  end

  def scheduled(at: 3.days.from_now)
    Appointment.create!(request: req, citizen: citizen, health_unit: unit, scheduled_at: at, scheduled_by_user: reception,
                        status: "scheduled", confirmation_deadline_at: at - 24.hours)
  end

  it "scheduled exige prazo" do
    expect do
      Appointment.create!(request: req, citizen: citizen, health_unit: unit, scheduled_at: 3.days.from_now,
                          scheduled_by_user: reception, status: "scheduled")
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "um só horário vivo por pedido" do
    scheduled
    expect { scheduled(at: 4.days.from_now) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "transições permitidas e proibidas" do
    a = scheduled
    expect { a.update!(status: "checked_in", ended_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /invalid transition/)
    a.reload.update!(status: "confirmed", confirmed_at: Time.current)
    a.update!(status: "no_show", ended_at: Time.current)
    expect { a.update!(status: "confirmed") }.to raise_error(ActiveRecord::StatementInvalid, /already ended/)
  end

  it "cancelado pelo cidadão exige motivo de 10+" do
    a = scheduled
    expect { a.update!(status: "cancelled_by_citizen", cancel_reason: "curto", ended_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid)
  end

  it "o que foi marcado nunca muda" do
    a = scheduled
    expect { Appointment.where(id: a.id).update_all(scheduled_at: 5.days.from_now) }
      .to raise_error(ActiveRecord::StatementInvalid, /never change/)
  end

  it "today? usa o fuso da cidade" do
    travel_to(Time.zone.parse("2026-10-02 10:00")) do
      late = scheduled(at: Time.zone.parse("2026-10-02 23:30"))
      expect(late.today?).to be(true)
    end
  end
end
