require "rails_helper"

# Core-engine regression coverage for the weighted-scoring bug fixed in 8e1a9dc.
# Before the fix, #evaluate built trail entries as { step:, answer: } only, so
# Scoring::Weighted#call (which sums entry[:weight]) always scored 0 and every
# weighted protocol collapsed onto the lowest tier. These specs lock the trail
# contract and the resulting score/tier at the engine level — no controller,
# no database — so the regression cannot return silently.
RSpec.describe Protocols::Protocol do
  # Two weighted boolean steps: tosse (true => 5) -> febre (true => 4).
  # thresholds land 0..3 = baixa, 4..7 = media, 8+ = alta.
  let(:tosse) do
    Protocols::Step.new(
      id: "tosse", prompt: "Tosse?", answer_type: "boolean",
      branches: { "true" => "febre", "false" => "febre" },
      weights:  { "true" => 5, "false" => 0 }
    )
  end

  let(:febre) do
    Protocols::Step.new(
      id: "febre", prompt: "Febre?", answer_type: "boolean",
      branches: { "true" => nil, "false" => nil },
      weights:  { "true" => 4, "false" => 0 }
    )
  end

  let(:scoring) do
    Protocols::Scoring::Weighted.new(
      thresholds:   { "baixa" => 0, "media" => 4, "alta" => 8 },
      priority_map: { "baixa" => 9, "media" => 5, "alta" => 1 }
    )
  end

  let(:protocol) do
    described_class.new(
      name: "respiratoria", version: 1,
      steps: [tosse, febre], start_step_id: "tosse",
      scoring: scoring
    )
  end

  describe "#evaluate with weighted scoring" do
    subject(:outcome) { protocol.evaluate("tosse" => "true", "febre" => "true") }

    it "scores the sum of the answered weights (non-zero) — guards 8e1a9dc" do
      expect(outcome.score).to eq(9)
    end

    it "lands the tier matching that score, not the lowest tier" do
      expect(outcome.tier).to eq("alta")
      expect(outcome.priority).to eq(1)
    end

    it "carries the per-answer weight on every trail entry" do
      # This is the exact field whose absence caused the bug: each entry must
      # expose :weight so Scoring::Weighted#call can sum it.
      expect(outcome.trail).to all(include(:weight))
      expect(outcome.trail.sum { |e| e[:weight] }).to eq(outcome.score)
    end

    it "keeps step/answer alongside the weight in the trail" do
      expect(outcome.trail).to eq(
        [
          { step: :tosse, answer: "true", weight: 5 },
          { step: :febre, answer: "true", weight: 4 }
        ]
      )
    end
  end

  describe "#evaluate tier selection across the threshold range" do
    it "picks the middle tier for a mid-range score" do
      outcome = protocol.evaluate("tosse" => "true", "febre" => "false") # 5 + 0
      expect(outcome.score).to eq(5)
      expect(outcome.tier).to eq("media")
    end

    it "picks the lowest tier only when the score genuinely is the lowest" do
      outcome = protocol.evaluate("tosse" => "false", "febre" => "false") # 0 + 0
      expect(outcome.score).to eq(0)
      expect(outcome.tier).to eq("baixa")
    end
  end

  describe "#evaluate with missing answers" do
    it "returns a pending outcome awaiting the unanswered step" do
      outcome = protocol.evaluate("tosse" => "true")
      expect(outcome).to be_pending
      expect(outcome.awaiting).to eq(:febre)
    end
  end
end
