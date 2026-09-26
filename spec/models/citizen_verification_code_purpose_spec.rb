require "rails_helper"

RSpec.describe CitizenVerificationCode do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "check_in exige triagem e verification não aceita triagem" do
    base = { citizen: citizen, code_digest: "x", expires_at: 10.minutes.from_now }
    expect { described_class.create!(base.merge(purpose: "check_in")) }
      .to raise_error(ActiveRecord::StatementInvalid, /ck_citizen_verification_codes_purpose_target/)
    expect(described_class.create!(base).purpose).to eq("verification")
  end
end
