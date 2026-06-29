require "rails_helper"

RSpec.describe Protocols::Validation::Graph do
  def reachable_def
    {
      "start_step_id" => "a",
      "steps" => [
        { "id" => "a", "answer_type" => "boolean", "branches" => { "true" => "b", "false" => nil } },
        { "id" => "b", "answer_type" => "boolean", "branches" => { "true" => nil, "false" => nil } }
      ]
    }
  end

  it "accepts a fully reachable graph with valid keys" do
    expect(Protocols::Validation::Graph.call(reachable_def)).to eq([])
  end

  it "flags a step unreachable from start_step_id" do
    d = reachable_def
    d["steps"] << { "id" => "orphan", "answer_type" => "boolean", "branches" => { "true" => nil, "false" => nil } }
    expect(Protocols::Validation::Graph.call(d)).to include("unreachable step: orphan")
  end

  it "flags a branch key that is not valid for a boolean step" do
    d = reachable_def
    d["steps"][0]["branches"]["maybe"] = nil
    expect(Protocols::Validation::Graph.call(d)).to include(a_string_matching(/branch key 'maybe' invalid for boolean step a/))
  end

  it "flags a weight key outside the enum options" do
    d = {
      "start_step_id" => "s",
      "steps" => [
        { "id" => "s", "answer_type" => "enum", "options" => %w[low high],
          "branches" => { "low" => nil, "high" => nil }, "weights" => { "low" => 1, "mid" => 2 } }
      ]
    }
    expect(Protocols::Validation::Graph.call(d)).to include(a_string_matching(/weight key 'mid' invalid for enum step s/))
  end
end
