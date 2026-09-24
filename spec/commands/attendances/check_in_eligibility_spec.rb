require "rails_helper"

RSpec.describe Attendances::CheckInEligibility do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:staff) { User.create!(email_address: "a@cidade.gov.br", password: "senha-segura-123") }

  it "elegível: concluída há até 3 dias e sem atendimento" do
    fresh = completed_web_triage_for(citizen, completed_at: 71.hours.ago)
    expect(described_class.check(fresh)).to eq(:ok)
    expect(described_class.eligible_for(Citizen.where(id: citizen.id))).to eq([fresh])
  end

  it "antiga e já atendida não são elegíveis" do
    old = completed_web_triage_for(citizen, completed_at: 73.hours.ago)
    expect(described_class.check(old)).to eq(:triage_too_old)
    fresh = completed_web_triage_for(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"))
    Attendance.create!(triage: fresh, citizen: fresh.conversation.citizen, health_unit: create_unit,
                       checked_in_by_user: staff, checked_in_at: Time.current, check_in_method: "code")
    expect(described_class.check(fresh)).to eq(:already_checked_in)
  end
end
