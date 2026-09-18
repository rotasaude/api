require "rails_helper"

# Spec da API de manutenção §7: o token é um login que não expira em 8h, então
# ele nasce com validade obrigatória, escopo restringível e um segredo que
# existe uma única vez — no banco fica só o digest.
RSpec.describe MaintenanceToken do
  include ActiveSupport::Testing::TimeHelpers

  let(:maintainer) { Maintainer.create!(email_address: "tok-#{SecureRandom.hex(3)}@rotasaude.app") }

  def issue(**overrides)
    described_class.issue!(**{ maintainer: maintainer, name: "ci", access: "read_write",
                               city_slugs: [], expires_at: 30.days.from_now }.merge(overrides))
  end

  it "returns the secret once, stores only a digest, and carries the environment prefix" do
    token, secret = issue

    expect(secret).to start_with(described_class.prefix)
    expect(token.token_digest).not_to include(secret)
    expect(token.token_prefix).to eq(described_class.prefix)
    expect(described_class.where(token_digest: secret).count).to eq(0)
    expect(described_class.digest_for(secret)).to eq(token.token_digest)
  end

  it "authenticates a usable secret and refuses every unusable one" do
    token, secret = issue

    expect(described_class.authenticate(secret)).to eq(token)
    expect(described_class.authenticate("#{described_class.prefix}nao-existe")).to be_nil
    expect(described_class.authenticate("rsm_other_#{secret.split('_').last}")).to be_nil
    expect(described_class.authenticate(nil)).to be_nil

    token.revoke!
    expect(described_class.authenticate(secret)).to be_nil
  end

  it "refuses an expired secret and one whose owner was deactivated" do
    _expired, expired_secret = issue(expires_at: 1.hour.from_now)
    travel_to(2.hours.from_now) { expect(described_class.authenticate(expired_secret)).to be_nil }

    _live, live_secret = issue
    Maintainer.create!(email_address: "second-#{SecureRandom.hex(3)}@rotasaude.app") # último ativo não desativa (Plano 3)
    maintainer.deactivate!
    expect(described_class.authenticate(live_secret)).to be_nil
  end

  it "requires an expiry inside the ceiling and a known access level" do
    expect { issue(expires_at: nil) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { issue(expires_at: (described_class::MAX_TTL + 1.day).from_now) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { issue(access: "admin") }.to raise_error(ActiveRecord::RecordInvalid)
    expect { issue(name: " ") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "answers what its scope allows" do
    read_token, _ = issue(access: "read")
    scoped, _ = issue(city_slugs: %w[curitiba])

    expect(read_token.read_only?).to be(true)
    expect(scoped.read_only?).to be(false)
    expect(scoped.allows_city?("curitiba")).to be(true)
    expect(scoped.allows_city?("maringa")).to be(false)
    expect(read_token.allows_city?("qualquer")).to be(true)   # lista vazia = todas
  end

  it "records use without touching updated_at semantics" do
    token, _ = issue

    token.touch_use!(ip: "10.0.0.9")

    expect(token.reload.last_used_at).to be_present
    expect(token.last_used_ip).to eq("10.0.0.9")
  end

  # I4 (fix round 2): o carimbo é de MINUTOS, não de requisição. Sem o teto,
  # cada chamada de automação reescrevia a linha do token.
  it "does not rewrite last_used_at inside the touch window" do
    token, _ = issue
    token.touch_use!(ip: "10.0.0.9")
    first = token.reload.last_used_at

    token.touch_use!(ip: "10.0.0.10")

    expect(token.reload.last_used_at).to eq(first)
    expect(token.last_used_ip).to eq("10.0.0.9")

    travel_to(described_class::TOUCH_WINDOW.from_now + 1.minute) do
      token.touch_use!(ip: "10.0.0.10")
      expect(token.reload.last_used_at).to be > first
      expect(token.last_used_ip).to eq("10.0.0.10")
    end
  end

  # M4 (fix round 2): o ramo do TETO não estava guardado por
  # `expires_at_changed?` como o de "já passou". No dia em que MAX_TTL baixar,
  # todo token emitido sob o teto antigo fica insalvável — inclusive por
  # `revoke!`, que é `update!`, e portanto a desativação do dono quebra junto.
  it "keeps an existing token savable after the ceiling is lowered" do
    token, _ = issue(expires_at: 60.days.from_now)

    stub_const("#{described_class}::MAX_TTL", 7.days)

    expect { token.revoke! }.not_to raise_error
    expect(token.reload.revoked_at).to be_present
    expect { issue(expires_at: 60.days.from_now) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "allows revoking a token whose expiry has already passed" do
    token, _ = issue(expires_at: 1.hour.from_now)

    travel_to(2.hours.from_now) do
      expect { token.revoke! }.not_to raise_error
      expect(token.reload.revoked_at).to be_present
    end
  end

  it "raises for an environment with no mapped prefix" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("canary"))

    expect { described_class.prefix }.to raise_error(KeyError, /canary/)
  end
end
