require "rails_helper"

RSpec.describe AnonymizeRevokedTriageJob, type: :job do
  # Same slug/database_url as TEST_CITY_A: with_city(city.slug) then re-enters
  # the shard the harness already has open, so fixtures created below on the
  # default connection and the job's own with_city block share one session
  # (a distinct random shard pointed at the same physical database would be a
  # second, separate Postgres session — see idempotent_consumer_transaction_spec.rb
  # for the pattern that keeps the two apart on purpose).
  let!(:city) do
    create(:city, slug: TEST_CITY_A.slug, status: "active", database_url: city_database_url("rota_saude_test_city_a"))
  end

  def definition_hash
    {
      "name" => "rev-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  def event_args(conversation_id, event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "consent.revoked", city_slug: city.slug,
      payload: { "conversation_id" => conversation_id, "consent_id" => SecureRandom.uuid, "reason" => "revogar" } }
  end

  it "scrubs clinical fields of the aborted_by_revocation triage, keeps the audit shell" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    convo = Conversation.create!(phone: "+551133", state: "revoked")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                            status: "aborted_by_revocation",
                            answers: { "s1" => "true" }, outcome: { "tier" => "baixa" },
                            tier: "baixa", priority: 9, current_step: "s1", completed_at: Time.current)

    described_class.new.perform(**event_args(convo.id))

    t = Triage.find(triage.id)
    expect(t.answers).to eq({})
    expect(t.outcome).to be_nil
    expect(t.tier).to be_nil
    expect(t.priority).to be_nil
    expect(t.current_step).to be_nil
    expect(t.status).to eq("aborted_by_revocation")
    expect(t.protocol_name).to eq("rev-demo")
    expect(t.completed_at).to be_present
  end

  it "is idempotent across distinct deliveries (scrub of already-empty is a no-op)" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    convo = Conversation.create!(phone: "+551134", state: "revoked")
    Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                   status: "aborted_by_revocation", answers: { "s1" => "true" }, tier: "baixa")

    described_class.new.perform(**event_args(convo.id))
    expect {
      described_class.new.perform(**event_args(convo.id)) # distinct event_id
    }.not_to raise_error

    expect(Triage.where(conversation_id: convo.id).first.answers).to eq({})
  end

  it "does not touch a completed triage or another conversation's triage" do
    pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active", definition: definition_hash)
    target = Conversation.create!(phone: "+551135", state: "revoked")
    Triage.create!(conversation: target, protocol_definition: pd, protocol_name: "rev-demo",
                   status: "aborted_by_revocation", answers: { "s1" => "true" })
    completed_convo = Conversation.create!(phone: "+551136", state: "completed")
    done = Triage.create!(conversation: completed_convo, protocol_definition: pd, protocol_name: "rev-demo",
                          status: "completed", answers: { "s1" => "true" }, tier: "baixa")

    described_class.new.perform(**event_args(target.id))
    expect(Triage.find(done.id).answers).to eq({ "s1" => "true" }) # completed untouched
  end
end
