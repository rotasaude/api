require "rails_helper"

RSpec.describe Operator do
  let(:operator) do
    described_class.create!(email_address: "  OP-#{SecureRandom.hex(3)}@X.COM  ", password: "s3nha-forte-1")
  end

  it "lives in the platform database" do
    expect(described_class.connection_db_config.database).to match(/platform/)
  end

  it "authenticates via has_secure_password" do
    expect(operator.authenticate("s3nha-forte-1")).to eq(operator)
    expect(operator.authenticate("errada")).to be false
  end

  it "normalizes email_address (strip + downcase)" do
    expect(operator.email_address).to eq(operator.email_address.strip.downcase)
    expect(operator.email_address).not_to match(/[A-Z]|\s/)
  end

  it "enforces case-insensitive uniqueness of email_address" do
    dup = described_class.new(email_address: operator.email_address.upcase, password: "outra-senha-1")
    expect(dup).not_to be_valid
    expect(dup.errors[:email_address]).to be_present
  end

  it "round-trips a password_reset token (single-use, 15 minutes)" do
    token = operator.generate_token_for(:password_reset)
    expect(described_class.find_by_token_for(:password_reset, token)).to eq(operator)

    operator.update!(password: "outra-senha-2")
    expect(described_class.find_by_token_for(:password_reset, token)).to be_nil
  end

  it "encrypts otp_secret at rest" do
    operator.update!(otp_secret: "SEGREDOOTP")
    raw = described_class.connection.select_value(
      described_class.sanitize_sql(["SELECT otp_secret FROM operators WHERE id = ?", operator.id])
    )
    expect(raw).not_to eq("SEGREDOOTP")
    expect(described_class.find(operator.id).otp_secret).to eq("SEGREDOOTP")
  end

  describe "#active?" do
    it "is true while deactivated_at is nil" do
      expect(operator).to be_active
    end

    it "is false once deactivated_at is set" do
      operator.update!(deactivated_at: Time.current)
      expect(operator).not_to be_active
    end
  end

  describe "#mfa_enrolled?" do
    it "is false without an otp_secret" do
      expect(operator).not_to be_mfa_enrolled
    end

    it "is true once otp_enabled and otp_secret are set" do
      operator.update!(otp_enabled: true, otp_secret: "SEGREDOOTP")
      expect(operator).to be_mfa_enrolled
    end
  end

  describe "#deactivate!" do
    it "sets deactivated_at and destroys sessions in a transaction" do
      session = operator.operator_sessions.create!

      operator.deactivate!

      expect(operator.reload.deactivated_at).to be_present
      expect(OperatorSession.exists?(session.id)).to be false
    end
  end

  it "does not respond to operator? or role_in? (no membership concept for Operator)" do
    expect(operator).not_to respond_to(:operator?)
    expect(operator).not_to respond_to(:role_in?)
  end
end
