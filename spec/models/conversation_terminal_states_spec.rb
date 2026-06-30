require "rails_helper"

RSpec.describe "Conversation terminal states (F-02.2)", type: :model do
  let(:muni) { create(:municipality) }

  let(:definition_hash) do
    {
      "name" => "terminal-demo", "version" => 1, "start_step_id" => "s1",
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

  it "accepts the aborted_by_cancellation triage status" do
    pd = ProtocolDefinition.create!(name: "terminal-demo", version: 1, status: "active",
                                    municipality_id: muni.id, definition: definition_hash)
    convo = Conversation.create!(municipality_id: muni.id, phone: "+5511990000010", state: "consented")
    triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "terminal-demo",
                            municipality_id: muni.id, status: "in_progress")
    expect { triage.update!(status: :aborted_by_cancellation) }.not_to raise_error
    expect(triage.reload.status).to eq("aborted_by_cancellation")
  end

  it "accepts completed / declined / cancelled conversation states" do
    convo = Conversation.create!(municipality_id: muni.id, phone: "+5511990000011", state: "consented")
    expect { convo.update!(state: :completed) }.not_to raise_error
    expect(convo.reload.state_completed?).to be(true)
    convo.update!(state: :declined);  expect(convo.reload.state_declined?).to be(true)
    convo.update!(state: :cancelled); expect(convo.reload.state_cancelled?).to be(true)
  end
end
