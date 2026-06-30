require "rails_helper"
require Rails.root.join("spec/support/admin_rls")

RSpec.describe SweepAbandonedConversationsJob, type: :job do
  self.use_transactional_tests = false

  before { clean_admin_tables }
  after  { clean_admin_tables }

  def definition_hash
    {
      "name" => "sweep-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  # Builds scenario fixtures via the real admin (BYPASSRLS) connection.
  # Renamed from setup_fixtures to avoid conflict with ActiveRecord::TestFixtures#setup_fixtures.
  def build_scenario(&block)
    as_admin do
      muni = Municipality.create!(name: "Sweep City", slug: "sweep-city", ibge_code: "3500010")
      pd = ProtocolDefinition.create!(name: "sweep-demo", version: 1, status: "active",
                                      municipality_id: muni.id, definition: definition_hash)
      block.call(muni, pd)
    end
  end

  def make_convo(muni, phone:, state:, updated_at:)
    c = Conversation.create!(municipality_id: muni.id, phone: phone, state: state)
    c.update_columns(updated_at: updated_at)
    c
  end

  def make_triage(muni, pd, convo, status:, updated_at:)
    t = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "sweep-demo",
                       municipality_id: muni.id, status: status)
    t.update_columns(updated_at: updated_at)
    t
  end

  it "abandons an idle awaiting_consent conversation with no triage" do
    convo = nil
    build_scenario { |muni, _pd| convo = make_convo(muni, phone: "+551100", state: "awaiting_consent", updated_at: 30.hours.ago) }
    described_class.new.perform(idle_hours: 24)
    expect(as_admin { Conversation.find(convo.id).state }).to eq("abandoned")
  end

  it "abandons a consented conversation and aborts its stale in-progress triage" do
    convo = triage = nil
    build_scenario do |muni, pd|
      convo = make_convo(muni, phone: "+551101", state: "consented", updated_at: 30.hours.ago)
      triage = make_triage(muni, pd, convo, status: "in_progress", updated_at: 30.hours.ago)
    end
    described_class.new.perform(idle_hours: 24)
    expect(as_admin { Conversation.find(convo.id).state }).to eq("abandoned")
    expect(as_admin { Triage.find(triage.id).status }).to eq("aborted_by_timeout")
  end

  it "leaves a recent conversation untouched" do
    convo = nil
    build_scenario { |muni, _pd| convo = make_convo(muni, phone: "+551102", state: "awaiting_consent", updated_at: 1.hour.ago) }
    described_class.new.perform(idle_hours: 24)
    expect(as_admin { Conversation.find(convo.id).state }).to eq("awaiting_consent")
  end

  it "leaves a conversation that completed a triage untouched" do
    convo = nil
    build_scenario do |muni, pd|
      convo = make_convo(muni, phone: "+551103", state: "consented", updated_at: 30.hours.ago)
      make_triage(muni, pd, convo, status: "completed", updated_at: 30.hours.ago)
    end
    described_class.new.perform(idle_hours: 24)
    expect(as_admin { Conversation.find(convo.id).state }).to eq("consented")
  end

  it "leaves a conversation with a fresh in-progress triage untouched" do
    convo = nil
    build_scenario do |muni, pd|
      convo = make_convo(muni, phone: "+551104", state: "consented", updated_at: 30.hours.ago)
      make_triage(muni, pd, convo, status: "in_progress", updated_at: 1.hour.ago)
    end
    described_class.new.perform(idle_hours: 24)
    expect(as_admin { Conversation.find(convo.id).state }).to eq("consented")
  end
end
