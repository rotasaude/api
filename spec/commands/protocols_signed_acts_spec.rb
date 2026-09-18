require "rails_helper"

# Spec §4/§5: publicar e ativar exigem duas assinaturas válidas cada; o
# mantenedor executa o ato quando elas existem e é recusado quando não.
RSpec.describe "Protocol acts that require signatures" do
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
  let(:maintainer_actor) do
    Maintenance::MaintainerActor.new(
      Maintainer.create!(email_address: "sa-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                         otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    )
  end

  def version(v = 1) = ProtocolDefinition.find_by!(name: "dengue", version: v)

  def in_review!(v = 1)
    ProtocolDefinition.create!(name: "dengue", version: v, status: "in_review",
                               definition: protocol_definition_hash(version: v))
  end

  describe "Publish" do
    it "publishes with two valid publication signatures" do
      in_review!
      sign!(version, purpose: "publication", by: ana)
      sign!(version, purpose: "publication", by: bia)

      expect(Protocols::Publish.call(version: 1, name: "dengue", by: publisher).ok?).to be(true)
      expect(version.status).to eq("published")
    end

    it "refuses with one signature, saying how many are missing and how many reviewers are eligible" do
      in_review!
      sign!(version, purpose: "publication", by: ana)
      bia

      result = Protocols::Publish.call(version: 1, name: "dengue", by: publisher)

      expect(result.reason).to eq(:signatures_missing)
      expect(result.message).to eq("falta 1 assinatura de publicação; revisores elegíveis na cidade: 2")
      expect(version.status).to eq("in_review")
    end

    it "no longer publishes straight from a draft" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash)

      expect(Protocols::Publish.call(version: 1, name: "dengue", by: publisher).reason).to eq(:invalid_state)
    end

    it "lets the maintainer publish when the city's signatures exist, and refuses it when they do not" do
      in_review!
      expect(Protocols::Publish.call(version: 1, name: "dengue", by: maintainer_actor).reason).to eq(:signatures_missing)

      sign!(version, purpose: "publication", by: ana)
      sign!(version, purpose: "publication", by: bia)
      correlation_id = SecureRandom.uuid

      expect(Protocols::Publish.call(version: 1, name: "dengue", by: maintainer_actor,
                                     correlation_id: correlation_id).ok?).to be(true)
      expect(DomainEvent.find_by!(name: "protocol.published").payload)
        .to include("actor" => maintainer_actor.id, "actor_kind" => "maintainer", "correlation_id" => correlation_id)
    end

    it "does not accept activation signatures for publication" do
      in_review!
      sign!(version, purpose: "activation", by: ana)
      sign!(version, purpose: "activation", by: bia)

      expect(Protocols::Publish.call(version: 1, name: "dengue", by: publisher).reason).to eq(:signatures_missing)
    end

    # Concurrency: the pre-lock read can be stale by the time Publish writes.
    # Simulate the race deterministically — capture an in-memory snapshot
    # taken while the row was still in_review and fully signed, then let a
    # concurrent edit (SaveDraft sending it back to draft, per Task 4) commit
    # through a separate path, and hand Publish the stale snapshot instead of
    # a fresh read (ProtocolDefinition.where is the only class-level reader
    # Publish uses, so stubbing it stands in for "the read that happened
    # before the concurrent write committed"). Without the post-lock
    # re-check, Publish would write "published" over content nobody signed.
    it "refuses under the lock when a concurrent edit already sent the version back to draft" do
      in_review!
      sign!(version, purpose: "publication", by: ana)
      sign!(version, purpose: "publication", by: bia)
      stale = version

      ProtocolDefinition.find(stale.id).update!(status: "draft")
      allow(ProtocolDefinition).to receive(:where).and_return([ stale ])

      result = Protocols::Publish.call(version: 1, name: "dengue", by: publisher)

      expect(result.reason).to eq(:invalid_state)
      expect(ProtocolDefinition.find(stale.id).status).to eq("draft")
    end
  end

  describe "Activate" do
    def published!(v = 1)
      ProtocolDefinition.create!(name: "dengue", version: v, status: "published",
                                 definition: protocol_definition_hash(version: v))
    end

    it "activates with two activation signatures and records the act" do
      published!
      sign!(version, purpose: "activation", by: ana)
      sign!(version, purpose: "activation", by: bia)

      expect(Protocols::Activate.call(version: 1, name: "dengue", by: publisher).ok?).to be(true)
      expect(version.status).to eq("active")
      expect(version.activations.pluck(:kind, :actor_id)).to eq([ [ "signed", publisher.id ] ])
    end

    it "refuses without activation signatures, even with publication signatures" do
      published!
      sign!(version, purpose: "publication", by: ana)
      sign!(version, purpose: "publication", by: bia)

      expect(Protocols::Activate.call(version: 1, name: "dengue", by: publisher).reason).to eq(:signatures_missing)
    end

    it "accepts the same reviewers who signed the publication (S8)" do
      published!
      %w[publication activation].each do |purpose|
        sign!(version, purpose: purpose, by: ana)
        sign!(version, purpose: purpose, by: bia)
      end

      expect(Protocols::Activate.call(version: 1, name: "dengue", by: publisher).ok?).to be(true)
    end

    it "consumes the signatures: activating the same version again requires signing again" do
      published!
      published!(2)
      [ 1, 2 ].each do |v|
        sign!(version(v), purpose: "activation", by: ana)
        sign!(version(v), purpose: "activation", by: bia)
      end
      Protocols::Activate.call(version: 1, name: "dengue", by: publisher)
      travel(1.second)
      Protocols::Activate.call(version: 2, name: "dengue", by: publisher)
      travel(1.second)

      expect(Protocols::Activate.call(version: 1, name: "dengue", by: publisher).reason).to eq(:signatures_missing)

      sign!(version(1), purpose: "activation", by: ana)
      sign!(version(1), purpose: "activation", by: bia)
      expect(Protocols::Activate.call(version: 1, name: "dengue", by: publisher).ok?).to be(true)
    end

    it "lets the maintainer activate when the signatures exist, and records it as the actor" do
      published!
      sign!(version, purpose: "activation", by: ana)
      sign!(version, purpose: "activation", by: bia)

      expect(Protocols::Activate.call(version: 1, name: "dengue", by: maintainer_actor).ok?).to be(true)
      expect(version.activations.sole).to have_attributes(actor_id: maintainer_actor.id, actor_kind: "maintainer")
    end

    it "keeps R1: a draft never becomes active" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash)

      expect(Protocols::Activate.call(version: 1, name: "dengue", by: publisher).reason).to eq(:not_published)
    end

    # Same race as Publish, on the other end of the lifecycle: a concurrent
    # Retire commits "retired" between the un-locked read and Activate's
    # write. Without the post-lock re-check, Activate would create an
    # activation act — and the ProtocolActivation append-only row to prove it
    # — for a version nobody can retract from "active" back to "retired".
    it "refuses under the lock when a concurrent retire already moved the version out of published" do
      published!
      sign!(version, purpose: "activation", by: ana)
      sign!(version, purpose: "activation", by: bia)
      stale = version

      ProtocolDefinition.find(stale.id).update!(status: "retired")
      allow(ProtocolDefinition).to receive(:where).and_return([ stale ])

      result = Protocols::Activate.call(version: 1, name: "dengue", by: publisher)

      expect(result.reason).to eq(:not_published)
      expect(ProtocolDefinition.find(stale.id).status).to eq("retired")
      expect(ProtocolActivation.count).to eq(0)
    end
  end

  describe "Retire" do
    it "keeps Retire as it was, now saying who acted and how" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "published", definition: protocol_definition_hash)

      expect(Protocols::Retire.call(version: 1, name: "dengue", by: publisher).ok?).to be(true)
      expect(DomainEvent.find_by!(name: "protocol.retired").payload).to include("actor_kind" => "user")
    end

    # I1: the pre-lock read can be stale by the time Retire writes. A
    # concurrent Activate (or RevertActivation) can commit "active" over the
    # same version between the un-locked read (still "published") and
    # Retire's write — without the post-lock re-check, Retire would write
    # "retired" over the city's active protocol (R4 violated, city left
    # without an active version). ProtocolDefinition.where is the only
    # class-level reader Retire uses, so stubbing it stands in for "the read
    # that happened before the concurrent write committed".
    it "refuses under the lock when a concurrent activate already moved the version to active" do
      published = ProtocolDefinition.create!(name: "dengue", version: 1, status: "published",
                                              definition: protocol_definition_hash)
      stale = published

      ProtocolDefinition.find(stale.id).update!(status: "active", activated_at: Time.current)
      # Retire chains a second .where(name:) onto the version scope when
      # `name:` is given (unlike Publish/Activate's single .where(conditions)
      # call), so the stub omits `name:` here to keep the single-call stub
      # standing in for "the read that happened before the concurrent write
      # committed".
      allow(ProtocolDefinition).to receive(:where).and_return([ stale ])

      result = Protocols::Retire.call(version: 1, by: publisher)

      expect(result.reason).to eq(:active_in_city)
      expect(ProtocolDefinition.find(stale.id).status).to eq("active")
    end
  end
end
