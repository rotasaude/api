require "rails_helper"

# F-03.7 — trail estruturado de explicabilidade (ADR-0009). O motor registra,
# no Outcome, POR QUE chegou ao tier/priority: nota de cada passo (`scored`),
# regra da tabela que casou (`rule_matched`), override de priority_when
# (`priority_rule`) e tier atribuído (`tier_assigned`). Só referências
# (ids de passo, índices de regra, pesos, tiers) — NUNCA a resposta crua.
RSpec.describe "Protocols explanation trail" do
  def step(id, branches:, weights: {})
    Protocols::Step.new(id: id, prompt: "#{id}?", answer_type: "boolean",
                        branches: branches, weights: weights)
  end

  let(:tosse) { step("tosse", branches: { "true" => "febre", "false" => "febre" }, weights: { "true" => 5, "false" => 0 }) }
  let(:febre) { step("febre", branches: { "true" => nil, "false" => nil }, weights: { "true" => 4, "false" => 0 }) }

  def kinds(outcome) = outcome.explanation.map { |e| e[:ev] }

  describe "weighted" do
    let(:protocol) do
      Protocols::Protocol.new(
        name: "resp", version: 1, steps: [tosse, febre], start_step_id: "tosse",
        scoring: Protocols::Scoring::Weighted.new(
          thresholds: { "baixa" => 0, "media" => 4, "alta" => 8 },
          priority_map: { "baixa" => 9, "media" => 5, "alta" => 1 }
        )
      )
    end

    subject(:outcome) { protocol.evaluate("tosse" => "true", "febre" => "false") }

    it "records one scored entry per answered step with its weight" do
      scored = outcome.explanation.select { |e| e[:ev] == "scored" }
      expect(scored).to eq([
        { ev: "scored", rule: "weighted", ref: "step:tosse", out: 5 },
        { ev: "scored", rule: "weighted", ref: "step:febre", out: 0 }
      ])
    end

    it "ends with the tier assigned by threshold and the score as reference" do
      expect(outcome.explanation.last).to eq(ev: "tier_assigned", rule: "threshold", ref: "score:5", out: "media")
    end

    it "never carries the raw answer" do
      expect(outcome.explanation).to all(satisfy { |e| e.keys.sort == %i[ev out ref rule] })
      expect(outcome.explanation.map { |e| e[:ref].to_s }.join).not_to include("true")
    end

    it "is part of Outcome#to_h so it freezes with the triage" do
      expect(outcome.to_h[:explanation]).to eq(outcome.explanation)
    end
  end

  describe "decision_table" do
    let(:protocol) do
      Protocols::Protocol.new(
        name: "resp", version: 1, steps: [tosse, febre], start_step_id: "tosse",
        scoring: Protocols::Scoring::DecisionTable.new(
          rules: [
            { "when" => { "tosse" => "true", "febre" => "true" }, "tier" => "alta", "priority" => 1 },
            { "when" => { "tosse" => "true" }, "tier" => "media", "priority" => 5 }
          ],
          fallback: { tier: "baixa", priority: 9 }
        )
      )
    end

    it "names the index of the first rule that matched" do
      outcome = protocol.evaluate("tosse" => "true", "febre" => "false")
      expect(outcome.explanation).to eq([
        { ev: "rule_matched", rule: "decision_table", ref: "rule:1", out: "media" },
        { ev: "tier_assigned", rule: "decision_table", ref: "rule:1", out: "media" }
      ])
    end

    it "first match wins when several rules hold" do
      outcome = protocol.evaluate("tosse" => "true", "febre" => "true")
      expect(outcome.tier).to eq("alta")
      expect(outcome.explanation.first[:ref]).to eq("rule:0")
    end

    it "says fallback when no rule matched" do
      outcome = protocol.evaluate("tosse" => "false", "febre" => "false")
      expect(outcome.explanation).to eq([
        { ev: "rule_matched", rule: "decision_table", ref: "fallback", out: "baixa" },
        { ev: "tier_assigned", rule: "decision_table", ref: "fallback", out: "baixa" }
      ])
    end
  end

  describe "priority_when" do
    let(:protocol) do
      Protocols::Protocol.new(
        name: "resp", version: 1, steps: [tosse, febre], start_step_id: "tosse",
        scoring: Protocols::Scoring::Weighted.new(
          thresholds: { "baixa" => 0, "alta" => 8 }, priority_map: { "baixa" => 9, "alta" => 1 }
        ),
        priority_rules: [
          { "when" => { "tosse" => "false" }, "priority" => 7 },
          { "when" => { "febre" => "true" }, "priority" => 2 }
        ]
      )
    end

    it "records the escalating rule index and the final priority" do
      outcome = protocol.evaluate("tosse" => "false", "febre" => "true")
      expect(outcome.priority).to eq(2)
      expect(outcome.explanation).to include(ev: "priority_rule", rule: "priority_when", ref: "rule:1", out: 2)
    end

    it "records nothing when no rule escalates" do
      outcome = protocol.evaluate("tosse" => "true", "febre" => "false")
      expect(kinds(outcome)).not_to include("priority_rule")
    end
  end

  it "a pending outcome has no explanation" do
    protocol = Protocols::Protocol.new(name: "resp", version: 1, steps: [tosse, febre], start_step_id: "tosse")
    expect(protocol.evaluate("tosse" => "true").explanation).to eq([])
  end
end
