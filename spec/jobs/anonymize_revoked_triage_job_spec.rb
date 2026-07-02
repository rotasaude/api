require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe AnonymizeRevokedTriageJob, type: :job do
  self.use_transactional_tests = false
  before { clean_admin_tables }
  after  { clean_admin_tables }

  def definition_hash
    {
      "name" => "rev-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  def event_args(conversation_id, municipality_id, event_id: SecureRandom.uuid)
    { event_id: event_id, event_name: "consent.revoked", municipality_id: municipality_id,
      payload: { "conversation_id" => conversation_id, "consent_id" => SecureRandom.uuid, "reason" => "revogar" } }
  end

  it "scrubs clinical fields of the aborted_by_revocation triage, keeps the audit shell" do
    ctx = nil
    as_admin do
      muni = Municipality.create!(name: "Rev City", slug: "rev-city", ibge_code: "3500050")
      pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active",
                                      municipality_id: muni.id, definition: definition_hash)
      convo = Conversation.create!(municipality_id: muni.id, phone: "+551133", state: "revoked")
      triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                              municipality_id: muni.id, status: "aborted_by_revocation",
                              answers: { "s1" => "true" }, outcome: { "tier" => "baixa" },
                              tier: "baixa", priority: 9, current_step: "s1", completed_at: Time.current)
      ctx = { muni: muni.id, convo: convo.id, triage: triage.id }
    end

    described_class.new.perform(**event_args(ctx[:convo], ctx[:muni]))

    as_admin do
      t = Triage.find(ctx[:triage])
      expect(t.answers).to eq({})
      expect(t.outcome).to be_nil
      expect(t.tier).to be_nil
      expect(t.priority).to be_nil
      expect(t.current_step).to be_nil
      expect(t.status).to eq("aborted_by_revocation")
      expect(t.protocol_name).to eq("rev-demo")
      expect(t.completed_at).to be_present
    end
  end

  it "is idempotent across distinct deliveries (scrub of already-empty is a no-op)" do
    ctx = nil
    as_admin do
      muni = Municipality.create!(name: "Rev City 2", slug: "rev-city-2", ibge_code: "3500051")
      pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active",
                                      municipality_id: muni.id, definition: definition_hash)
      convo = Conversation.create!(municipality_id: muni.id, phone: "+551134", state: "revoked")
      Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "rev-demo",
                     municipality_id: muni.id, status: "aborted_by_revocation",
                     answers: { "s1" => "true" }, tier: "baixa")
      ctx = { muni: muni.id, convo: convo.id }
    end
    described_class.new.perform(**event_args(ctx[:convo], ctx[:muni]))
    expect {
      described_class.new.perform(**event_args(ctx[:convo], ctx[:muni])) # distinct event_id
    }.not_to raise_error
    as_admin { expect(Triage.where(conversation_id: ctx[:convo]).first.answers).to eq({}) }
  end

  it "does not touch a completed triage or another conversation's triage" do
    ctx = nil
    as_admin do
      muni = Municipality.create!(name: "Rev City 3", slug: "rev-city-3", ibge_code: "3500052")
      pd = ProtocolDefinition.create!(name: "rev-demo", version: 1, status: "active",
                                      municipality_id: muni.id, definition: definition_hash)
      target = Conversation.create!(municipality_id: muni.id, phone: "+551135", state: "revoked")
      Triage.create!(conversation: target, protocol_definition: pd, protocol_name: "rev-demo",
                     municipality_id: muni.id, status: "aborted_by_revocation", answers: { "s1" => "true" })
      completed_convo = Conversation.create!(municipality_id: muni.id, phone: "+551136", state: "completed")
      done = Triage.create!(conversation: completed_convo, protocol_definition: pd, protocol_name: "rev-demo",
                            municipality_id: muni.id, status: "completed", answers: { "s1" => "true" }, tier: "baixa")
      ctx = { muni: muni.id, convo: target.id, done: done.id }
    end
    described_class.new.perform(**event_args(ctx[:convo], ctx[:muni]))
    as_admin { expect(Triage.find(ctx[:done]).answers).to eq({ "s1" => "true" }) } # completed untouched
  end
end
