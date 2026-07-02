require "rails_helper"

RSpec.describe Protocols::PriorityRules do
  let(:answers) { { "idade" => "85", "febre" => "true" } }

  it "returns the min priority among matching rules" do
    rules = [
      { "when" => { "gt" => ["idade", 80] }, "priority" => 1 },
      { "when" => { "eq" => ["febre", "true"] }, "priority" => 3 }
    ]
    expect(described_class.override_for(rules, answers)).to eq(1)
  end

  it "ignores non-matching rules" do
    rules = [
      { "when" => { "gt" => ["idade", 90] }, "priority" => 1 },
      { "when" => { "eq" => ["febre", "true"] }, "priority" => 3 }
    ]
    expect(described_class.override_for(rules, answers)).to eq(3)
  end

  it "is nil when no rule matches / empty / nil" do
    none = [{ "when" => { "gt" => ["idade", 90] }, "priority" => 1 }]
    expect(described_class.override_for(none, answers)).to be_nil
    expect(described_class.override_for([], answers)).to be_nil
    expect(described_class.override_for(nil, answers)).to be_nil
  end

  it "supports a legacy flat when and symbol keys" do
    expect(described_class.override_for([{ "when" => { "febre" => "true" }, "priority" => 2 }], answers)).to eq(2)
    expect(described_class.override_for([{ when: { "eq" => ["febre", "true"] }, priority: 4 }], answers)).to eq(4)
  end
end
