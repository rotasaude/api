require "rails_helper"

RSpec.describe Protocols::Scoring::DecisionTable do
  def trail(pairs) = pairs.map { |step, answer| { step: step, answer: answer, weight: 0 } }

  describe "condition-DSL rules" do
    subject(:table) do
      described_class.new(
        rules: [
          { "when" => { "any" => [{ "gt" => ["idade", 60] }, { "eq" => ["febre", "true"] }] },
            "tier" => "alta", "priority" => 1 }
        ],
        fallback: { tier: "baixa", priority: 9 }
      )
    end

    it "matches when the condition holds (gt branch)" do
      outcome = table.call(trail([[:idade, "70"], [:febre, "false"]]))
      expect(outcome.tier).to eq("alta")
      expect(outcome.priority).to eq(1)
    end

    it "matches when the condition holds (eq branch)" do
      outcome = table.call(trail([[:idade, "20"], [:febre, "true"]]))
      expect(outcome.tier).to eq("alta")
    end

    it "falls back when the condition does not hold" do
      outcome = table.call(trail([[:idade, "20"], [:febre, "false"]]))
      expect(outcome.tier).to eq("baixa")
      expect(outcome.priority).to eq(9)
    end
  end

  describe "legacy flat when (regression)" do
    subject(:table) do
      described_class.new(
        rules: [{ "when" => { "febre" => "true" }, "tier" => "alta", "priority" => 1 }],
        fallback: { tier: "baixa", priority: 9 }
      )
    end

    it "still matches exact-equality maps" do
      expect(table.call(trail([[:febre, "true"]])).tier).to eq("alta")
      expect(table.call(trail([[:febre, "false"]])).tier).to eq("baixa")
    end
  end
end
