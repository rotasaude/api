require "rails_helper"

RSpec.describe Mfa::Enroll do
  let!(:user) { User.create!(email_address: "bob@example.org", password: "secret123") }

  it "gera secret, otpauth_uri e 10 recovery codes" do
    out = described_class.call(user)
    expect(out[:secret]).to be_present
    expect(out[:otpauth_uri]).to start_with("otpauth://totp/")
    expect(out[:recovery_codes].length).to eq(10)
    expect(user.reload.otp_enabled).to be(false)
    expect(user.otp_secret).to eq(out[:secret])
  end
end
