require "rails_helper"

RSpec.describe "Protocols::Publish gate (F-03.9)" do
  let(:publisher) do
    u = User.create!(email_address: "pub@example.org", password: "secret123")
    Membership.create!(user: u, role: "protocol_publisher", granted_at: Time.current)
    u
  end

  # Passes the minimal before_save Validator (so it can be saved as in_review),
  # but fails the full gate: priority_map value 99 is out of the schema's 1..9.
  def invalid_definition
    {
      "name" => "respiratoria", "version" => 1, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 99 } }
    }
  end

  def valid_definition
    invalid_definition.merge(
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    )
  end

  def make_pd(definition)
    ProtocolDefinition.create!(
      name: "respiratoria", version: 1,
      status: "in_review", definition: definition
    )
  end

  # Was an `around` opening a transaction with SET LOCAL app.municipality_id (RLS).
  # Removed in 5c-1: raising before `ex.run` (e.g. `muni`) skipped rspec-rails'
  # fixture teardown and leaked the pinned transaction into the rest of the suite.
  # The example already runs inside TEST_CITY_A's connection and its fixture transaction.
  before { Current.city = TEST_CITY_A }

  after { Current.reset; Rails.cache.clear }

  it "rejects publishing a definition that fails the gate" do
    pd = make_pd(invalid_definition)
    result = Protocols::Publish.call(version: 1, by: publisher)
    expect(result.failure?).to be true
    expect(result.reason).to eq(:invalid)
    expect(pd.reload.status).to eq("in_review")
  end

  it "publishes a definition that passes the gate" do
    pd = make_pd(valid_definition)
    sign!(pd, purpose: "publication", by: make_reviewer!)
    sign!(pd, purpose: "publication", by: make_reviewer!)

    result = Protocols::Publish.call(version: 1, by: publisher)
    expect(result.ok?).to be true
    expect(pd.reload.status).to eq("published")
  end
end
