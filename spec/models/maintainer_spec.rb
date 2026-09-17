require "rails_helper"

# Spec da API de manutenção §6: identidade própria, separada de Operator, com
# poderes totais — então a força está na autenticação: TOTP obrigatório,
# bloqueio por conta e desativação que mata sessões na hora.
RSpec.describe Maintainer do
  include ActiveSupport::Testing::TimeHelpers

  def build_maintainer(email: "m-#{SecureRandom.hex(3)}@rotasaude.app")
    described_class.create!(email_address: email)
  end

  it "normalizes and refuses a duplicate e-mail, whatever the case" do
    build_maintainer(email: "Alguem@Rotasaude.APP")

    expect(described_class.find_by(email_address: "alguem@rotasaude.app")).to be_present
    expect { build_maintainer(email: "ALGUEM@rotasaude.app") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "is not enrolled until it has a password and a confirmed TOTP" do
    maintainer = build_maintainer
    expect(maintainer.enrolled?).to be(false)

    maintainer.update!(password: "s3nha-forte-1")
    expect(maintainer.enrolled?).to be(false)

    Mfa::Enroll.call(maintainer)
    expect(maintainer.reload.enrolled?).to be(false)

    maintainer.update!(otp_enabled_at: Time.current)
    expect(maintainer.reload.enrolled?).to be(true)
  end

  it "locks the account after five failures and stays locked with the right password" do
    maintainer = build_maintainer

    (described_class::LOCKOUT_ATTEMPTS - 1).times { maintainer.register_failure! }
    expect(maintainer.reload.locked?).to be(false)

    maintainer.register_failure!
    expect(maintainer.reload.locked?).to be(true)
    expect(maintainer.locked_until).to be_within(5.seconds).of(described_class::LOCKOUT_WINDOW.from_now)

    travel_to(described_class::LOCKOUT_WINDOW.from_now + 1.second) do
      expect(maintainer.reload.locked?).to be(false)
    end
  end

  it "clears the failure count on a good login" do
    maintainer = build_maintainer
    2.times { maintainer.register_failure! }

    maintainer.clear_failures!

    expect(maintainer.reload.failed_attempts).to eq(0)
    expect(maintainer.locked_until).to be_nil
  end

  it "deactivates, killing every session at once" do
    maintainer = build_maintainer
    maintainer.maintainer_sessions.create!(mfa_verified_at: Time.current, last_seen_at: Time.current)

    maintainer.deactivate!

    expect(maintainer.reload.active?).to be(false)
    expect(MaintainerSession.where(maintainer_id: maintainer.id)).to be_empty
  end

  it "knows it is the last active maintainer" do
    first = build_maintainer
    expect(first.last_active?).to be(true)

    second = build_maintainer
    expect(first.reload.last_active?).to be(false)

    second.deactivate!
    expect(first.reload.last_active?).to be(true)
  end

  # Bloco aninhado: aqui `described_class` seria MaintainerInvitation, então o
  # mantenedor é criado pelo nome da classe, não por described_class.
  describe MaintainerInvitation do
    it "stores only a digest and is usable once, inside the window" do
      maintainer = Maintainer.create!(email_address: "inv-#{SecureRandom.hex(3)}@rotasaude.app")
      invitation, token = MaintainerInvitation.issue!(maintainer: maintainer)

      expect(token).to be_present
      expect(invitation.token_digest).not_to include(token)
      expect(MaintainerInvitation.find_by(token_digest: MaintainerInvitation.digest_for(token))).to eq(invitation)
      expect(invitation.usable?).to be(true)

      invitation.update!(used_at: Time.current)
      expect(invitation.reload.usable?).to be(false)

      other, _token = MaintainerInvitation.issue!(maintainer: maintainer)
      travel_to(MaintainerInvitation::TTL.from_now + 1.second) { expect(other.reload.usable?).to be(false) }
    end
  end
end
