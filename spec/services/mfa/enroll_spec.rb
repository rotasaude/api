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

  # C1 (fix round 2): a matrícula do mantenedor não emite segundo fator
  # estático. O default continua sendo o de sempre — User e Operator não mudam.
  it "emite matrícula SEM recovery code quando pedido" do
    out = described_class.call(user, recovery_codes: false)

    expect(out).not_to have_key(:recovery_codes)
    expect(out[:secret]).to be_present
    expect(out[:otpauth_uri]).to start_with("otpauth://totp/")
    expect(user.reload.otp_recovery_codes).to eq([])
    expect(user.otp_enabled).to be(false)
  end
end
