require "rails_helper"

RSpec.describe "Triage/Conversation terminal states", type: :model do
  let(:definition_hash) do
    {
      "name" => "sweep-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  # Was an `around` opening a transaction with SET LOCAL app.municipality_id (RLS).
  # Removed in 5c-1: raising before `ex.run` (e.g. `muni`) skipped rspec-rails'
  # fixture teardown and leaked the pinned transaction into the rest of the suite.
  # The example already runs inside TEST_CITY_A's connection and its fixture transaction.
  before { Current.city = TEST_CITY_A }

  after { Current.reset }

  it "accepts the aborted_by_timeout triage status" do
    pd = ProtocolDefinition.create!(name: "sweep-demo", version: 1, status: "active", definition: definition_hash)
    convo = Conversation.create!(phone: "+5511990000001", state: "consented")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "sweep-demo",
                            status: "in_progress")
    expect { triage.update!(status: :aborted_by_timeout) }.not_to raise_error
    expect(triage.reload.status).to eq("aborted_by_timeout")
  end

  it "accepts the abandoned conversation state" do
    convo = Conversation.create!(phone: "+5511990000002", state: "consented")
    expect { convo.update!(state: :abandoned) }.not_to raise_error
    expect(convo.reload.state_abandoned?).to be(true)
  end
end
