require "rails_helper"

# Spec §4: quem edita fica registrado e não assina; enviar para revisão congela
# o conteúdo que se assina; editar em revisão volta a rascunho.
RSpec.describe "Protocol authoring and signing" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:author) do
    User.create!(email_address: "au-#{SecureRandom.hex(3)}@example.org", password: "secret123").tap do |u|
      Membership.create!(user: u, role: "protocol_author", granted_at: Time.current)
    end
  end
  let(:reviewer) { make_reviewer! }
  let(:maintainer_actor) do
    Maintenance::MaintainerActor.new(
      Maintainer.create!(email_address: "am-#{SecureRandom.hex(3)}@rotasaude.app", password: "s3nha-forte-1",
                         otp_secret: ROTP::Base32.random, otp_enabled_at: Time.current)
    )
  end
  let(:correlation_id) { SecureRandom.uuid }

  def save!(by:, definition: protocol_definition_hash, **kw)
    Protocols::SaveDraft.call(definition: definition, by: by, **kw)
  end

  def version = ProtocolDefinition.find_by!(name: "dengue", version: 1)

  describe "SaveDraft" do
    it "records every editor, user or maintainer, with the digest they saved" do
      save!(by: author)
      save!(by: maintainer_actor, correlation_id: correlation_id)

      rows = version.contributions.order(:created_at)
      expect(rows.map(&:actor_kind)).to eq(%w[user maintainer])
      expect(rows.map(&:actor_id)).to eq([ author.id, maintainer_actor.id ])
      expect(rows.map(&:content_digest).uniq).to eq([ version.content_digest ])
      event = DomainEvent.where(name: "protocol.draft_saved").order(:occurred_at).last
      expect(event.payload).to include("actor" => maintainer_actor.id, "actor_kind" => "maintainer",
                                       "correlation_id" => correlation_id)
    end

    it "sends a version under review back to draft when it is edited" do
      save!(by: author)
      version.update!(status: "in_review")

      save!(by: author)

      expect(version.status).to eq("draft")
    end

    it "still refuses to edit a published version" do
      save!(by: author)
      version.update!(status: "published")

      expect(save!(by: author).reason).to eq(:version_not_editable)
    end

    # M9: the model's before_save (validate_definition_shape) throws :abort
    # when Protocols::Validator rejects the definition's shape — a halted
    # callback chain makes save! raise ActiveRecord::RecordNotSaved, not
    # RecordInvalid (the AR-level presence/inclusion validations all pass;
    # only Protocols::Validator, run by hand inside before_save, rejects it).
    # Without the RecordNotSaved rescue this 500s instead of failing as a
    # user error.
    it "reports a definition the validator rejects as a user error instead of raising" do
      invalid = protocol_definition_hash.merge("start_step_id" => "no-such-step")

      result = save!(by: author, definition: invalid)

      expect(result.failure?).to be(true)
      expect(result.reason).to eq(:invalid_definition)
      expect(result.message).to match(/start_step_id/)
      expect(ProtocolDefinition.find_by(name: "dengue", version: 1)).to be_nil
    end

    # Concurrency: the pre-lock read can be stale by the time SaveDraft writes.
    # Simulate the race deterministically — capture an in-memory snapshot taken
    # when the row was still draft, then let a concurrent Publish commit
    # "published" through a separate path, and hand SaveDraft the stale
    # snapshot instead of a fresh read (find_or_initialize_by is the only
    # reader in the command, so stubbing it stands in for "the read that
    # happened before the concurrent write committed").
    it "refuses under the lock when a concurrent write already left the version un-editable" do
      save!(by: author)
      stale = version

      ProtocolDefinition.find(stale.id).update!(status: "published")
      allow(ProtocolDefinition).to receive(:find_or_initialize_by).and_return(stale)

      result = save!(by: author)

      expect(result.reason).to eq(:version_not_editable)
      expect(ProtocolDefinition.find(stale.id).status).to eq("published")
    end
  end

  describe "SubmitForReview" do
    it "moves a draft to in_review and records the digest under review" do
      save!(by: author)

      result = Protocols::SubmitForReview.call(name: "dengue", version: 1, by: author)

      expect(result.ok?).to be(true)
      expect(version.status).to eq("in_review")
      expect(DomainEvent.find_by!(name: "protocol.submitted_for_review").payload)
        .to include("content_digest" => version.content_digest, "actor_kind" => "user")
    end

    it "is allowed to the maintainer" do
      save!(by: author)

      expect(Protocols::SubmitForReview.call(name: "dengue", version: 1, by: maintainer_actor).ok?).to be(true)
    end

    it "refuses a version that is not a draft" do
      save!(by: author)
      version.update!(status: "published")

      expect(Protocols::SubmitForReview.call(name: "dengue", version: 1, by: author).reason).to eq(:invalid_state)
    end

    # Same race as SaveDraft, on the other read: find_by is the only reader
    # SubmitForReview uses, so stubbing it hands the command a snapshot taken
    # before a concurrent write committed.
    it "refuses under the lock when a concurrent write already moved the version out of draft" do
      save!(by: author)
      stale = version

      ProtocolDefinition.find(stale.id).update!(status: "in_review")
      allow(ProtocolDefinition).to receive(:find_by).and_return(stale)

      result = Protocols::SubmitForReview.call(name: "dengue", version: 1, by: author)

      expect(result.reason).to eq(:invalid_state)
      expect(ProtocolDefinition.find(stale.id).status).to eq("in_review")
    end

    # The dangerous half of the same race: status is unchanged (still draft)
    # but the CONTENT committed since the stale read is invalid. The pre-lock
    # gate check (run on the stale, valid content) would wrongly pass; only
    # re-running the gate on the locked row's actual content catches it.
    it "reruns the gate on the locked content when a concurrent edit invalidated it since the read" do
      save!(by: author)
      stale = version

      invalid_content = protocol_definition_hash.merge(
        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 99 } }
      )
      save!(by: author, definition: invalid_content)

      allow(ProtocolDefinition).to receive(:find_by).and_return(stale)

      result = Protocols::SubmitForReview.call(name: "dengue", version: 1, by: author)

      expect(result.reason).to eq(:invalid)
      expect(ProtocolDefinition.find(stale.id).status).to eq("draft")
    end
  end

  describe "Sign" do
    before do
      save!(by: author)
      Protocols::SubmitForReview.call(name: "dengue", version: 1, by: author)
    end

    def sign(by:, purpose: "publication")
      Protocols::Sign.call(name: "dengue", version: 1, purpose: purpose, by: by)
    end

    it "records a reviewer's signature on the current content" do
      result = sign(by: reviewer)

      expect(result.ok?).to be(true)
      expect(result.payload[:signature]).to have_attributes(signer_user_id: reviewer.id, purpose: "publication",
                                                            content_digest: version.content_digest)
      expect(DomainEvent.find_by!(name: "protocol.signed").payload)
        .to include("purpose" => "publication", "actor" => reviewer.id, "content_digest" => version.content_digest)
    end

    it "refuses the maintainer, even though it passes every role question" do
      expect(sign(by: maintainer_actor).reason).to eq(:maintainer_cannot_sign)
      expect(version.signatures).to be_empty
    end

    it "refuses someone without the reviewer role" do
      expect(sign(by: author).reason).to eq(:forbidden)
    end

    it "refuses a reviewer who edited the version" do
      Membership.create!(user: author, role: "protocol_reviewer", granted_at: Time.current)

      expect(sign(by: author).reason).to eq(:contributor_cannot_sign)
    end

    it "refuses a second signature on the same content for the same purpose" do
      sign(by: reviewer)

      expect(sign(by: reviewer).reason).to eq(:already_signed)
    end

    it "signs publication only under review, and activation only when published" do
      expect(sign(by: reviewer, purpose: "activation").reason).to eq(:invalid_state)

      version.update!(status: "published")
      expect(sign(by: reviewer, purpose: "publication").reason).to eq(:invalid_state)
      expect(sign(by: reviewer, purpose: "activation").ok?).to be(true)
    end

    it "refuses an unknown purpose and an unknown version" do
      expect(sign(by: reviewer, purpose: "x").reason).to eq(:invalid_purpose)
      expect(Protocols::Sign.call(name: "dengue", version: 9, purpose: "publication", by: reviewer).reason)
        .to eq(:not_found)
    end

    # Same race, at the signing act: find_by is the only reader Sign uses, so
    # stubbing it hands Sign a snapshot taken while the version was still
    # in_review, while a concurrent Publish already committed "published".
    # A publication signature must never land on a version no longer in_review.
    it "refuses under the lock when a concurrent Publish already moved the version out of in_review" do
      stale = version

      ProtocolDefinition.find(stale.id).update!(status: "published")
      allow(ProtocolDefinition).to receive(:find_by).and_return(stale)

      result = sign(by: reviewer)

      expect(result.reason).to eq(:invalid_state)
      expect(ProtocolDefinition.find(stale.id).status).to eq("published")
      expect(ProtocolSignature.count).to eq(0)
    end
  end
end
