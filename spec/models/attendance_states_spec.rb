require "rails_helper"

RSpec.describe Attendance do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:reception) { staff_with("recepcao@cidade.gov.br", "citizen_verifier") }
  let(:doctor) { staff_with("medica@cidade.gov.br", "health_professional") }
  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "nasce waiting" do
    expect(waiting_attendance(citizen, unit: unit, by: reception).status).to eq("waiting")
  end

  it "o banco aceita waiting → in_care → closed com desfecho clínico" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    expect { a.update!(status: "closed", outcome: "discharged", closed_by_user: doctor, closed_at: Time.current) }
      .not_to raise_error
  end

  it "o banco recusa desfecho clínico direto de waiting" do
    a = waiting_attendance(citizen, unit: unit, by: reception)
    expect { a.update!(status: "closed", outcome: "discharged", closed_by_user: doctor, closed_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /invalid transition/)
  end

  it "o banco recusa left a partir de in_care" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    expect { a.update!(status: "closed", outcome: "left", closed_by_user: doctor, closed_at: Time.current) }
      .to raise_error(ActiveRecord::StatementInvalid, /invalid transition/)
  end

  it "o banco recusa voltar de in_care para waiting e mudar a chamada" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    expect { Attendance.transaction(requires_new: true) { a.update_columns(status: "waiting") } }
      .to raise_error(ActiveRecord::StatementInvalid)
    expect do
      Attendance.transaction(requires_new: true) { Attendance.where(id: a.id).update_all(called_at: 1.hour.ago) }
    end.to raise_error(ActiveRecord::StatementInvalid, /call never changes/)
  end

  it "exige exatamente uma origem: triagem ou horário" do
    a = waiting_attendance(citizen, unit: unit, by: reception)
    expect { Attendance.transaction(requires_new: true) { Attendance.where(id: a.id).update_all(triage_id: nil) } }
      .to raise_error(ActiveRecord::StatementInvalid)
  end

  it "retorno aceita nota e recusa unidade de destino" do
    a = in_care!(waiting_attendance(citizen, unit: unit, by: reception), by: doctor)
    expect do
      a.update!(status: "closed", outcome: "return", referral_note: "reavaliar em 15 dias",
                closed_by_user: doctor, closed_at: Time.current)
    end.not_to raise_error
  end

  it "triagem sem atendimento continua elegível mesmo havendo atendimento sem triagem (NOT IN com NULL)" do
    first = waiting_attendance(citizen, unit: unit, by: reception)
    in_care!(first, by: doctor)
    first.update!(status: "closed", outcome: "return", closed_by_user: doctor, closed_at: Time.current)
    req = request_for(first)
    appt = Appointment.create!(request: req, citizen: citizen, health_unit: unit, scheduled_at: 1.hour.from_now,
                               scheduled_by_user: reception, status: "confirmed", confirmed_at: Time.current)
    Attendance.create!(appointment: appt, citizen: citizen, health_unit: unit, checked_in_by_user: reception,
                       checked_in_at: Time.current, check_in_method: "code")

    fresh = completed_web_triage_for(citizen)
    expect(Attendances::CheckInEligibility.eligible_for(Citizen.where(id: citizen.id))).to include(fresh)
  end

  it "prioridade vem da triagem raiz quando nasce de horário" do
    first = waiting_attendance(citizen, unit: unit, by: reception)
    first.triage.update_columns(priority: 2)
    in_care!(first, by: doctor)
    first.update!(status: "closed", outcome: "return", closed_by_user: doctor, closed_at: Time.current)
    req = request_for(first)
    appt = Appointment.create!(request: req, citizen: citizen, health_unit: unit, scheduled_at: 1.hour.from_now,
                               scheduled_by_user: reception, status: "confirmed", confirmed_at: Time.current)
    second = Attendance.create!(appointment: appt, citizen: citizen, health_unit: unit, checked_in_by_user: reception,
                                checked_in_at: Time.current, check_in_method: "code")
    expect(second.priority).to eq(2)
    expect(second.root_triage).to eq(first.triage)
  end
end
