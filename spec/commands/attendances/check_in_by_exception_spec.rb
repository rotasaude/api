require "rails_helper"

RSpec.describe Attendances::CheckInByException do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:stranger) { Citizen.create!(cpf: "11144477735", phone: "+5541911112222") }
  let(:staff) { User.create!(email_address: "atendente@cidade.gov.br", password: "senha-segura-123") }
  let(:unit) { create_unit }

  def call(triage_id:, reason: "cidadão sem celular")
    described_class.call(cpf: "529.982.247-25", triage_id: triage_id, health_unit_id: unit.id, reason: reason, by: staff)
  end

  it "lista só triagens elegíveis do CPF" do
    fresh = completed_web_triage_for(citizen)
    completed_web_triage_for(Citizen.create!(cpf: "52998224725", phone: "+5541933334444"), completed_at: 4.days.ago)
    expect(Attendances::EligibleTriages.call(cpf: citizen.cpf).payload[:triages]).to eq([fresh])
  end

  it "abre com motivo e não valida o cadastro" do
    t = completed_web_triage_for(citizen)
    a = call(triage_id: t.id).payload[:attendance]
    expect(a).to have_attributes(check_in_method: "cpf_exception", exception_reason: "cidadão sem celular")
    expect(citizen.reload).to be_verification_level_declared
  end

  it "motivo curto" do
    t = completed_web_triage_for(citizen)
    expect(call(triage_id: t.id, reason: "curto").reason).to eq(:reason_too_short)
  end

  it "triagem de outro CPF: triage_not_eligible, nada criado" do
    other = completed_web_triage_for(stranger)
    expect(call(triage_id: other.id).reason).to eq(:triage_not_eligible)
    expect(Attendance.count).to eq(0)
  end
end
