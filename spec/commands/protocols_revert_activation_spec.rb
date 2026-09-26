require "rails_helper"

# Spec §6: voltar para a versão que estava em uso imediatamente antes, sem
# assinaturas, com motivo — e nunca reverter uma reversão, que reativaria a
# versão com erro sem assinatura nenhuma.
RSpec.describe Protocols::RevertActivation do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:publisher) do
    User.create!(email_address: "pb-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    end
  end
  let(:ana) { make_reviewer! }
  let(:bia) { make_reviewer! }

  def version(v) = ProtocolDefinition.find_by!(name: "dengue", version: v)

  def activate_signed!(v)
    ProtocolDefinition.find_by(name: "dengue", version: v) ||
      ProtocolDefinition.create!(name: "dengue", version: v, status: "published",
                                 definition: protocol_definition_hash(version: v))
    sign!(version(v), purpose: "activation", by: ana)
    sign!(version(v), purpose: "activation", by: bia)
    expect(Protocols::Activate.call(version: v, name: "dengue", by: publisher).ok?).to be(true)
    travel(1.second)
  end

  def revert(reason: "v2 prioriza febre errado", by: publisher)
    described_class.call(name: "dengue", by: by, reason: reason)
  end

  it "puts the previous version back in use without signatures, recording the reason" do
    activate_signed!(1)
    activate_signed!(2)

    result = revert

    expect(result.ok?).to be(true)
    expect([ version(1).status, version(2).status ]).to eq(%w[active published])
    expect(version(1).activations.order(:created_at).last)
      .to have_attributes(kind: "emergency_revert", reason: "v2 prioriza febre errado", actor_id: publisher.id)
    expect(DomainEvent.find_by!(name: "protocol.activation_reverted").payload)
      .to include("from_version" => 2, "to_version" => 1, "reason" => "v2 prioriza febre errado")
  end

  it "refuses to revert a revert" do
    activate_signed!(1)
    activate_signed!(2)
    revert
    travel(1.second)

    expect(revert.reason).to eq(:not_revertible)
    expect(version(1).status).to eq("active")
  end

  it "requires a reason" do
    activate_signed!(1)
    activate_signed!(2)

    expect(revert(reason: "  ").reason).to eq(:reason_required)
  end

  it "refuses when there is no previous activation" do
    activate_signed!(1)

    expect(revert.reason).to eq(:no_previous_activation)
  end

  it "refuses when the previous version was retired in the meantime" do
    activate_signed!(1)
    activate_signed!(2)
    version(1).update!(status: "retired", retired_at: Time.current)

    expect(revert.reason).to eq(:not_revertible)
  end

  it "refuses someone who cannot activate" do
    activate_signed!(1)
    activate_signed!(2)

    expect(revert(by: ana).reason).to eq(:forbidden)
  end

  it "refuses a version activated before signatures existed (no activation record)" do
    ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", definition: protocol_definition_hash)

    expect(revert.reason).to eq(:not_revertible)
  end

  it "reverts the first signed activation of a city to the baseline version" do
    legacy = ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", activated_at: 3.days.ago,
                                        definition: protocol_definition_hash)
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil, created_at: 3.days.ago)
    activate_signed!(2)

    result = revert

    expect(result.ok?).to be(true)
    expect([ version(1).status, version(2).status ]).to eq(%w[active published])
  end

  it "refuses to revert while the only activation is the baseline" do
    legacy = ProtocolDefinition.create!(name: "dengue", version: 1, status: "active", definition: protocol_definition_hash)
    legacy.activations.create!(kind: "baseline", actor_kind: "system", actor_id: nil)

    expect(revert.reason).to eq(:not_revertible)
  end

  # Concurrency (P2): lock BOTH the current and target rows, in deterministic
  # id order, then re-check everything — including the activation history —
  # before writing. Simulate a stale read on the target: capture it while it
  # is still published, let a REAL concurrent Retire move it to retired, then
  # hand RevertActivation the stale snapshot instead of a fresh read.
  # ProtocolDefinition.find is the only reader the command uses to resolve
  # `target` from the previous activation, so stubbing it stands in for "the
  # read that happened before the concurrent retire committed". The pre-lock
  # fast check is fooled by the stale (still "published") snapshot and would
  # wrongly proceed — only target.lock! (which reloads via the row's own
  # locking read, untouched by the stub) refreshes it to "retired", and only
  # the post-lock re-check catches it before any write happens.
  it "refuses under the lock when the previous version was retired after the stale read" do
    activate_signed!(1)
    activate_signed!(2)
    stale_target = version(1)

    ProtocolDefinition.find_by!(id: stale_target.id).update!(status: "retired", retired_at: Time.current)
    allow(ProtocolDefinition).to receive(:find).and_return(stale_target)

    result = revert

    expect(result.reason).to eq(:not_revertible)
    expect(ProtocolDefinition.find_by!(id: stale_target.id).status).to eq("retired")
    expect(ProtocolActivation.count).to eq(2)
  end

  describe "expected_version" do
    it "reverts when the token matches the active version" do
      activate_signed!(1)
      activate_signed!(2)

      result = described_class.call(name: "dengue", by: publisher, reason: "motivo", expected_version: 2)

      expect(result.ok?).to be(true)
      expect(version(1).status).to eq("active")
    end

    # A corrida que o token existe para pegar: a tela mostrava a v2 como
    # vigente, alguém ativou a v3, e só então o clique chegou.
    it "refuses when the active version changed since the screen read it" do
      activate_signed!(1)
      activate_signed!(2)
      activate_signed!(3)

      result = described_class.call(name: "dengue", by: publisher, reason: "motivo", expected_version: 2)

      expect(result.failure?).to be(true)
      expect(result.reason).to eq(:current_version_changed)
      expect(result.message).to include("3")
      expect(version(3).status).to eq("active")
    end

    # Review Focus 1: é o que permite o rollout em três passos.
    it "reverts exactly as before when no token is sent" do
      activate_signed!(1)
      activate_signed!(2)

      expect(revert.ok?).to be(true)
      expect(version(1).status).to eq("active")
    end
  end
end
