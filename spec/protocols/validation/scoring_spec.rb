require "rails_helper"

RSpec.describe Protocols::Validation::Scoring do
  def steps
    [{ "id" => "tosse", "answer_type" => "boolean", "branches" => { "true" => nil, "false" => nil } }]
  end

  it "returns no errors when there is no scoring block" do
    expect(Protocols::Validation::Scoring.call({ "steps" => steps })).to eq([])
  end

  it "accepts a weighted scoring whose priority_map tiers are all thresholds" do
    d = { "steps" => steps,
          "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 },
                         "priority_map" => { "baixa" => 9, "alta" => 1 } } }
    expect(Protocols::Validation::Scoring.call(d)).to eq([])
  end

  it "flags a priority_map tier not present in thresholds" do
    d = { "steps" => steps,
          "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 },
                         "priority_map" => { "media" => 5 } } }
    expect(Protocols::Validation::Scoring.call(d)).to include("priority_map tier 'media' not in thresholds")
  end

  it "flags a decision_table when-clause referencing an unknown step" do
    d = { "steps" => steps,
          "scoring" => { "type" => "decision_table",
                         "rules" => [{ "when" => { "ausente" => "true" }, "tier" => "alta", "priority" => 1 }] } }
    expect(Protocols::Validation::Scoring.call(d)).to include("decision_table rule references unknown step ausente")
  end

  it "flags a decision_table when-clause with an invalid answer for the step" do
    d = { "steps" => steps,
          "scoring" => { "type" => "decision_table",
                         "rules" => [{ "when" => { "tosse" => "maybe" }, "tier" => "alta", "priority" => 1 }] } }
    expect(Protocols::Validation::Scoring.call(d)).to include("decision_table invalid answer 'maybe' for step tosse")
  end
end
