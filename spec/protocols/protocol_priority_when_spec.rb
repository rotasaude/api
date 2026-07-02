require "rails_helper"

RSpec.describe "Protocol priority_when (F-03.6)" do
  def build(priority_when:, weights: { "true" => 1, "false" => 0 })
    Protocols::Definitions.build(
      "name" => "pw-demo", "version" => 1, "start_step_id" => "grave",
      "steps" => [{ "id" => "grave", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil }, "weights" => weights }],
      "scoring" => { "type" => "weighted",
                     "thresholds" => { "baixa" => 0, "alta" => 1 },
                     "priority_map" => { "baixa" => 5, "alta" => 2 } },
      "priority_when" => priority_when
    )
  end

  it "escalates priority when a rule matches (min beats the mode)" do
    protocol = build(priority_when: [{ "when" => { "eq" => ["grave", "false"] }, "priority" => 1 }])
    outcome = protocol.evaluate("grave" => "false") # base tier baixa → priority 5
    expect(outcome.priority).to eq(1)
    expect(outcome.tier).to eq("baixa") # tier NOT changed, only priority
  end

  it "never de-escalates (a higher-number rule does not raise a more-urgent base)" do
    protocol = build(priority_when: [{ "when" => { "eq" => ["grave", "true"] }, "priority" => 9 }])
    outcome = protocol.evaluate("grave" => "true") # base tier alta → priority 2
    expect(outcome.priority).to eq(2)
  end

  it "leaves priority unchanged when no rule matches" do
    protocol = build(priority_when: [{ "when" => { "eq" => ["grave", "true"] }, "priority" => 1 }])
    outcome = protocol.evaluate("grave" => "false") # rule needs grave=true; base priority 5
    expect(outcome.priority).to eq(5)
  end

  it "is a no-op when there is no priority_when" do
    protocol = build(priority_when: nil)
    outcome = protocol.evaluate("grave" => "false")
    expect(outcome.priority).to eq(5)
  end

  it "round-trips priority_when in to_h" do
    rules = [{ "when" => { "eq" => ["grave", "false"] }, "priority" => 1 }]
    expect(build(priority_when: rules).to_h[:priority_when]).to eq(rules)
  end

  it "does not crash or escalate to 0 on a malformed priority_when rule" do
    protocol = build(priority_when: [{ "when" => { "eq" => ["grave", "false"] } }]) # rule sem priority
    outcome = nil
    expect { outcome = protocol.evaluate("grave" => "false") }.not_to raise_error
    expect(outcome.priority).to eq(5) # base mantida; regra inválida ignorada
  end
end
