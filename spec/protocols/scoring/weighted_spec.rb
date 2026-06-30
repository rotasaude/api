require "rails_helper"

# Unit-level regression coverage for Scoring::Weighted. The companion engine
# spec (spec/protocols/protocol_spec.rb) proves #evaluate now populates the
# :weight key; this spec pins the summation/tier contract that consumes it, so
# the two halves of the 8e1a9dc fix are locked independently.
RSpec.describe Protocols::Scoring::Weighted do
  subject(:scoring) do
    described_class.new(
      thresholds:   { "baixa" => 0, "media" => 4, "alta" => 8 },
      priority_map: { "baixa" => 9, "media" => 5, "alta" => 1 }
    )
  end

  describe "#call" do
    it "sums entry[:weight] into a non-zero score and picks the matching tier" do
      trail = [
        { step: :tosse, answer: "true", weight: 5 },
        { step: :febre, answer: "true", weight: 4 }
      ]
      outcome = scoring.call(trail)
      expect(outcome.score).to eq(9)
      expect(outcome.tier).to eq("alta")
      expect(outcome.priority).to eq(1)
    end

    it "falls back to the lowest tier only for a genuinely zero score" do
      trail = [{ step: :tosse, answer: "false", weight: 0 }]
      outcome = scoring.call(trail)
      expect(outcome.score).to eq(0)
      expect(outcome.tier).to eq("baixa")
    end

    it "returns priority 5 when the chosen tier is absent from priority_map" do
      bare = described_class.new(thresholds: { "x" => 0 })
      outcome = bare.call([{ step: :a, answer: "y", weight: 3 }])
      expect(outcome.tier).to eq("x")
      expect(outcome.priority).to eq(5)
    end
  end
end
