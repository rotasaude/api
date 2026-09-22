require "rails_helper"

# Propor e promover (spec do autenticador pendente §4): `start` nunca toca no
# segredo ativo, e só `confirm` promove. É isso que permite abandonar uma troca
# no meio sem ficar sem segundo fator.
RSpec.describe Mfa::PendingEnrollment do
  let(:user) do
    u = User.create!(email_address: "bia-#{SecureRandom.hex(3)}@example.org", password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    u.reload
  end

  def pending_code(u) = ROTP::TOTP.new(u.reload.otp_pending_secret).now

  describe ".start" do
    it "grava o pendente e não toca no ativo" do
      active_secret = user.otp_secret
      active_codes = user.otp_recovery_codes

      out = described_class.start(user)

      expect(out[:otpauth_uri]).to start_with("otpauth://totp/")
      expect(out[:recovery_codes].length).to eq(10)
      user.reload
      expect(user.otp_secret).to eq(active_secret)
      expect(user.otp_recovery_codes).to eq(active_codes)
      expect(user.otp_enabled).to be(true)
      expect(user.otp_pending_secret).to be_present
      expect(user.otp_pending_recovery_codes.length).to eq(10)
      expect(user.otp_pending_at).to be_within(5.seconds).of(Time.current)
    end

    it "o otpauth_uri leva o segredo pendente, não o ativo" do
      out = described_class.start(user)

      secret = URI.decode_www_form(URI.parse(out[:otpauth_uri]).query).to_h["secret"]
      expect(secret).to eq(user.reload.otp_pending_secret)
      expect(secret).not_to eq(user.otp_secret)
    end

    it "chamar de novo substitui o pendente" do
      first = described_class.start(user)[:recovery_codes]
      described_class.start(user)

      expect(user.reload.otp_pending_recovery_codes.length).to eq(10)
      expect(first.any? { |c| user.otp_pending_recovery_codes.any? { |h| BCrypt::Password.new(h) == c } }).to be(false)
    end
  end

  describe ".confirm" do
    it "promove o pendente e limpa" do
      codes = described_class.start(user)[:recovery_codes]
      pending_secret = user.reload.otp_pending_secret

      expect(described_class.confirm(user, code: pending_code(user))).to eq(:ok)

      user.reload
      expect(user.otp_secret).to eq(pending_secret)
      expect(user.otp_enabled).to be(true)
      expect(user.otp_pending_secret).to be_nil
      expect(user.otp_pending_recovery_codes).to eq([])
      expect(user.otp_pending_at).to be_nil
      expect(user.otp_recovery_codes.any? { |h| BCrypt::Password.new(h) == codes.first }).to be(true)
    end

    it "recusa sem pendente" do
      expect(described_class.confirm(user, code: "123456")).to eq(:no_pending_enrollment)
    end

    it "recusa e limpa um pendente vencido" do
      described_class.start(user)
      user.update!(otp_pending_at: 16.minutes.ago)

      expect(described_class.confirm(user, code: pending_code(user))).to eq(:enrollment_expired)
      expect(user.reload.otp_pending_secret).to be_nil
    end

    it "recusa o código do segredo ATIVO" do
      described_class.start(user)

      expect(described_class.confirm(user, code: ROTP::TOTP.new(user.otp_secret).now)).to eq(:invalid_code)
      expect(user.reload.otp_pending_secret).to be_present
    end

    it "recusa um código já usado" do
      described_class.start(user)
      code = pending_code(user)
      expect(described_class.confirm(user, code: code)).to eq(:ok)
      described_class.start(user)

      # O passo já foi consumido na promoção acima; o mesmo instante não serve
      # duas vezes, nem para um pendente novo.
      expect(described_class.confirm(user, code: pending_code(user))).to eq(:code_reused)
    end

    it "recusa um código de recuperação pendente (confirmar prova o autenticador novo)" do
      codes = described_class.start(user)[:recovery_codes]

      expect(described_class.confirm(user, code: codes.first)).to eq(:invalid_code)
    end
  end
end
