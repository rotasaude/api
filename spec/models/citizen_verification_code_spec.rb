require "rails_helper"

RSpec.describe Citizens::IssueVerificationCode do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; travel_back }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }

  it "emite 6 dígitos válidos por 10 minutos e guarda só o hash" do
    result = described_class.call(citizen: citizen)
    expect(result.payload[:code]).to match(/\A\d{6}\z/)
    expect(result.payload[:expires_at]).to be_within(1.second).of(10.minutes.from_now)
    expect(CitizenVerificationCode.last.code_digest).not_to include(result.payload[:code])
  end

  it "um código novo invalida o anterior" do
    first = described_class.call(citizen: citizen)
    described_class.call(citizen: citizen)
    expect(CitizenVerificationCode.usable.where(citizen: citizen).count).to eq(1)
    expect(Citizens::VerificationCodeMatch.call(cpf: citizen.cpf, code: first.payload[:code]).reason)
      .to eq(:invalid_code).or eq(:code_expired)
  end

  it "par já verificado não gera código" do
    user = User.create!(email_address: "a@cidade.gov.br", password: "senha-segura-123")
    CitizenVerification.create!(citizen: citizen, verified_by_user: user, verified_at: Time.current)
    expect(described_class.call(citizen: citizen).reason).to eq(:already_verified)
  end
end
