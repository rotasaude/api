# spec/commands/screenings/abandon_spec.rb
require "rails_helper"

# ADR 0030 (spec §3.2): abandonar devolve a pessoa à fila do acolhimento. A
# chamada e a saída sem atendimento abandonam a escuta em curso (Desvio 7;
# Review Focus 4).
RSpec.describe Screenings::Abandon do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1)) }
  let(:screening) { Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening] }

  it "abandona a escuta em curso; de novo → not_in_progress" do
    expect(described_class.call(screening: screening, by: nurse)).to be_ok
    expect(screening.reload.status).to eq("abandoned")
    expect(DomainEvent.where(name: "screening.abandoned").sole.payload)
      .to eq("screening_id" => screening.id, "attendance_id" => attendance.id, "user_id" => nurse.id)
    expect(described_class.call(screening: screening, by: nurse).reason).to eq(:not_in_progress)
  end

  it "a chamada do profissional abandona a escuta em curso" do
    doctor = screener!(unit, cbo: "225125")
    screening
    expect(Attendances::Call.call(attendance: attendance, health_unit_id: unit.id, by: doctor)).to be_ok
    expect(screening.reload.status).to eq("abandoned")
  end

  it "left abandona a escuta em curso (Review Focus 4)" do
    screening
    result = Attendances::Close.call(attendance: attendance, outcome: "left", referral_unit_id: nil, referral_note: nil,
                                     by: reception!)
    expect(result).to be_ok
    expect(screening.reload.status).to eq("abandoned")
  end

  it "a rota de desfecho não aceita os desfechos de escuta" do
    attendance.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)
    %w[oriented scheduled_from_screening].each do |outcome|
      expect(Attendances::Close.call(attendance: attendance, outcome: outcome, referral_unit_id: nil, referral_note: nil,
                                     by: nurse).reason).to eq(:invalid_outcome)
    end
  end
end
