require "rails_helper"

RSpec.describe "Triage/Conversation terminal states", type: :model do
  let(:muni) { create(:municipality) }

  let(:definition_hash) do
    {
      "name" => "sweep-demo", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil } }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 } }
    }
  end

  around do |ex|
    ApplicationRecord.transaction do
      Current.municipality_id = muni.id
      ApplicationRecord.connection.execute(
        ApplicationRecord.sanitize_sql(["SET LOCAL app.municipality_id = ?", muni.id])
      )
      ex.run
      raise ActiveRecord::Rollback
    end
  end

  after { Current.reset }

  it "accepts the aborted_by_timeout triage status" do
    pd = ProtocolDefinition.create!(name: "sweep-demo", version: 1, status: "active",
                                    municipality_id: muni.id, definition: definition_hash)
    convo = Conversation.create!(municipality_id: muni.id, phone: "+5511990000001", state: "consented")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "sweep-demo",
                            municipality_id: muni.id, status: "in_progress")
    expect { triage.update!(status: :aborted_by_timeout) }.not_to raise_error
    expect(triage.reload.status).to eq("aborted_by_timeout")
  end

  it "accepts the abandoned conversation state" do
    convo = Conversation.create!(municipality_id: muni.id, phone: "+5511990000002", state: "consented")
    expect { convo.update!(state: :abandoned) }.not_to raise_error
    expect(convo.reload.state_abandoned?).to be(true)
  end
end
