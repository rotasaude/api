require "rails_helper"
require "rotp"

RSpec.describe Mfa::Verify do
  let!(:user) { User.create!(email_address: "carol@example.org", password: "secret123") }
  before { @enroll = Mfa::Enroll.call(user) }

  it "aceita TOTP atual" do
    current = ROTP::TOTP.new(user.otp_secret).now
    expect(described_class.call(user, code: current)).to be true
  end

  it "rejeita código bobo" do
    expect(described_class.call(user, code: "000000")).to be false
  end

  it "consome recovery code (não aceita duas vezes)" do
    code = @enroll[:recovery_codes].first
    expect(described_class.call(user, code: code)).to be true
    expect(described_class.call(user, code: code)).to be false
  end
end
