require "rails_helper"

RSpec.describe Protocols::Condition do
  let(:answers) { { "idade" => "70", "febre" => "true", "tosse" => "false" } }
  def ev(node) = described_class.eval(node, answers)

  it "eq: matches exact string, else false" do
    expect(ev({ "eq" => ["febre", "true"] })).to be(true)
    expect(ev({ "eq" => ["febre", "false"] })).to be(false)
  end

  it "in: membership over the set (stringified)" do
    expect(ev({ "in" => ["idade", [70, 80]] })).to be(true)
    expect(ev({ "in" => ["idade", ["10", "20"]] })).to be(false)
  end

  it "gt/lt: numeric comparison" do
    expect(ev({ "gt" => ["idade", 60] })).to be(true)
    expect(ev({ "gt" => ["idade", 90] })).to be(false)
    expect(ev({ "lt" => ["idade", 90] })).to be(true)
  end

  it "gt/lt: missing or non-numeric answer is false (default-deny)" do
    expect(ev({ "gt" => ["ausente", 1] })).to be(false)
    expect(ev({ "gt" => ["febre", 1] })).to be(false)
  end

  it "all/any/not combinators" do
    expect(ev({ "all" => [{ "gt" => ["idade", 60] }, { "eq" => ["febre", "true"] }] })).to be(true)
    expect(ev({ "all" => [{ "gt" => ["idade", 60] }, { "eq" => ["tosse", "true"] }] })).to be(false)
    expect(ev({ "any" => [{ "eq" => ["tosse", "true"] }, { "eq" => ["febre", "true"] }] })).to be(true)
    expect(ev({ "not" => { "eq" => ["febre", "true"] } })).to be(false)
    expect(ev({ "not" => { "eq" => ["febre", "false"] } })).to be(true)
  end

  it "nested combinators" do
    node = { "any" => [{ "all" => [{ "gt" => ["idade", 65] }, { "eq" => ["febre", "true"] }] },
                       { "eq" => ["tosse", "true"] }] }
    expect(ev(node)).to be(true)
  end

  it "legacy flat map = AND of eq (single and multi key)" do
    expect(ev({ "febre" => "true" })).to be(true)
    expect(ev({ "febre" => "true", "tosse" => "false" })).to be(true)
    expect(ev({ "febre" => "true", "tosse" => "true" })).to be(false)
  end

  it "empty / nil / non-Hash / unknown operator => false (default-deny)" do
    expect(ev({})).to be(false)
    expect(ev(nil)).to be(false)
    expect(ev("x")).to be(false)
    expect(ev({ "zzz" => ["febre", "true"] })).to be(false)
  end

  it "malformed operand => false, never raises (totality)" do
    [{ "eq" => nil }, { "gt" => nil }, { "lt" => nil }, { "in" => nil },
     { "all" => nil }, { "any" => nil }, { "not" => nil },
     { "eq" => 5 }, { "eq" => "x" }, { "gt" => ["idade"] }].each do |bad|
      expect { described_class.eval(bad, answers) }.not_to raise_error
      expect(described_class.eval(bad, answers)).to be(false)
    end
  end

  it "documents the operator/legacy collision: a legacy step named like an operator is read as the operator (known quirk; publish-validation deferred)" do
    # {"eq" => "true"} é lido como operador eq com operando "true" (String, não [key,val]) => false
    expect(described_class.eval({ "eq" => "true" }, answers)).to be(false)
  end

  # ADR 0027: gte/lte com o mesmo guarda de gt/lt.
  it "gte/lte: inclusive numeric comparison, total on bad operands" do
    expect(ev({ "gte" => ["idade", 70] })).to be(true)
    expect(ev({ "gte" => ["idade", 71] })).to be(false)
    expect(ev({ "lte" => ["idade", 70] })).to be(true)
    expect(ev({ "lte" => ["idade", 69] })).to be(false)
    expect(ev({ "gte" => ["ausente", 1] })).to be(false)
    expect(ev({ "gte" => ["febre", 1] })).to be(false)
    expect(ev({ "gte" => ["idade", "abc"] })).to be(false)
    expect(ev({ "gte" => "idade" })).to be(false)
    expect(ev({ "lte" => ["idade"] })).to be(false)
  end

  it "evaluates reserved variables from a ConditionContext and keeps the answers-only call" do
    context = Protocols::ConditionContext.build(
      answers: answers, profile: { age: 60, sex: "female" }, outcome: { tier: "media", score: 15, priority: 5 }
    )
    expect(described_class.eval({ "all" => [{ "gte" => ["profile.age", 60] }, { "eq" => ["profile.sex", "female"] }] }, context)).to be(true)
    expect(described_class.eval({ "gte" => ["outcome.score", 15] }, context)).to be(true)
    expect(described_class.eval({ "eq" => ["outcome.priority", 5] }, context)).to be(true)
    expect(described_class.eval({ "eq" => ["febre", "true"] }, context)).to be(true)
    expect(described_class.eval({ "gte" => ["profile.age", 60] }, answers)).to be(false)
  end
end
