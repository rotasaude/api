require "rails_helper"

# Spec §7: o escopo é aplicado em PONTO ÚNICO. Este objeto é esse ponto — quem
# pergunta "pode escrever?" ou "alcança esta cidade?" pergunta aqui, e não
# reimplementa a regra no resolver.
RSpec.describe Maintenance::Credential do
  let(:maintainer) { Maintainer.create!(email_address: "cred-#{SecureRandom.hex(3)}@rotasaude.app") }
  let(:session) { maintainer.maintainer_sessions.create!(mfa_verified_at: Time.current, last_seen_at: Time.current) }

  def token(**overrides)
    record, _secret = MaintenanceToken.issue!(**{ maintainer: maintainer, name: "ci", access: "read_write",
                                                  city_slugs: [], expires_at: 10.days.from_now }.merge(overrides))
    record
  end

  it "describes a human session" do
    credential = described_class.session(session)

    expect(credential.human?).to be(true)
    expect(credential.token?).to be(false)
    expect(credential.read_only?).to be(false)
    expect(credential.maintainer).to eq(maintainer)
    expect(credential.allows_city?("curitiba")).to be(true)
    expect(credential.audit_payload).to eq({ "kind" => "session" })
  end

  it "describes a token, carrying its access level and city scope" do
    scoped = token(access: "read", city_slugs: %w[curitiba])
    credential = described_class.token(scoped)

    expect(credential.token?).to be(true)
    expect(credential.human?).to be(false)
    expect(credential.read_only?).to be(true)
    expect(credential.allows_city?("curitiba")).to be(true)
    expect(credential.allows_city?("maringa")).to be(false)
    expect(credential.audit_payload).to eq({ "kind" => "token", "token_id" => scoped.id })
  end
end
