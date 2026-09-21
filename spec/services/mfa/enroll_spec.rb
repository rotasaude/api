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

  # Os códigos de recuperação seguem a MESMA política de custo que o Rails
  # aplica à senha (has_secure_password): custo mínimo quando
  # ActiveModel::SecurePassword.min_cost está ligado (test), o custo padrão do
  # BCrypt fora disso. Com o custo fixo em 12, cada matrícula custava ~2,3 s em
  # teste — e specs de request que matriculam cinco usuários por exemplo
  # levavam ~12 s cada.
  describe "custo do hash dos códigos de recuperação" do
    around do |example|
      original = ActiveModel::SecurePassword.min_cost
      example.run
    ensure
      ActiveModel::SecurePassword.min_cost = original
    end

    def recovery_costs(user)
      user.reload.otp_recovery_codes.map { |digest| BCrypt::Password.new(digest).cost }.uniq
    end

    it "usa o custo mínimo quando a política de custo mínimo está ligada" do
      ActiveModel::SecurePassword.min_cost = true
      described_class.call(user)

      expect(recovery_costs(user)).to eq([ BCrypt::Engine::MIN_COST ])
    end

    it "usa o custo padrão do BCrypt fora dela" do
      ActiveModel::SecurePassword.min_cost = false
      described_class.call(user)

      expect(recovery_costs(user)).to eq([ BCrypt::Engine.cost ])
    end

    it "continua verificando um código emitido" do
      ActiveModel::SecurePassword.min_cost = true
      code = described_class.call(user)[:recovery_codes].first

      expect(user.reload.otp_recovery_codes.any? { |digest| BCrypt::Password.new(digest) == code }).to be(true)
    end
  end
end
