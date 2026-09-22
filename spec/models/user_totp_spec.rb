require "rails_helper"

# Um código de TOTP vale UMA vez para a conta, em qualquer endpoint (spec do
# autenticador pendente §3). Mesmo desenho de Maintainer#consume_totp!: guarda
# o PASSO consumido, nunca o código, e a própria gravação condicional é o
# teste — duas requisições simultâneas com o mesmo código não passam as duas.
RSpec.describe User, "consumo de passo do TOTP", type: :model do
  let(:user) do
    u = User.create!(email_address: "ana-#{SecureRandom.hex(3)}@example.org", password: "secret123")
    Mfa::Enroll.call(u)
    u.update!(otp_enabled: true)
    u.reload
  end

  def current_code = ROTP::TOTP.new(user.otp_secret).now

  it "aceita um código novo e recusa o mesmo código de novo" do
    code = current_code

    expect(user.consume_totp!(code)).to be(true)
    expect(user.reload.last_otp_step).to be_present
    expect(user.consume_totp!(code)).to be(false)
  end

  it "recusa um passo anterior ao último consumido" do
    step = Mfa::Verify.totp_step_for(user, current_code)
    user.update!(last_otp_step: step)

    expect(user.consume_totp_step!(step - 1)).to be(false)
    expect(user.reload.last_otp_step).to eq(step)
  end

  it "aceita o passo seguinte" do
    step = Mfa::Verify.totp_step_for(user, current_code)
    user.update!(last_otp_step: step)

    expect(user.consume_totp_step!(step + 1)).to be(true)
    expect(user.reload.last_otp_step).to eq(step + 1)
  end

  it "recusa um código que não é do segredo da conta" do
    expect(user.consume_totp!(ROTP::TOTP.new(ROTP::Base32.random).now)).to be(false)
  end

  it "só um vencedor quando o mesmo passo chega duas vezes pelo mesmo registro" do
    step = Mfa::Verify.totp_step_for(user, current_code)
    other = User.find(user.id)   # segunda instância, como duas requisições

    expect([ user.consume_totp_step!(step), other.consume_totp_step!(step) ].count(true)).to eq(1)
  end

  it "guarda o pendente sem tocar no segredo ativo" do
    active = user.otp_secret
    user.update!(otp_pending_secret: ROTP::Base32.random, otp_pending_at: Time.current)

    expect(user.reload.otp_secret).to eq(active)
    expect(user.otp_enabled).to be(true)
    expect(user.otp_pending_secret).to be_present
  end
end
