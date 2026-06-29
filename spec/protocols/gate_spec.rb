require "rails_helper"

RSpec.describe Protocols::Gate do
  def valid_def
    {
      "name" => "respiratoria", "version" => 1, "start_step_id" => "tosse",
      "steps" => [
        { "id" => "tosse", "prompt" => "Tosse?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 5, "false" => 0 } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "passes a fully valid definition" do
    result = Protocols::Gate.call(valid_def)
    expect(result.valid?).to be true
    expect(result.errors).to eq([])
  end

  it "returns only schema errors when the shape is invalid (short-circuits semantics)" do
    d = valid_def
    d["steps"][0]["answer_type"] = "color"      # schema violation
    d["steps"] << { "id" => "orphan", "answer_type" => "boolean", "branches" => {} } # would be a graph error
    result = Protocols::Gate.call(d)
    expect(result.valid?).to be false
    expect(result.errors).to all(start_with("schema:"))
  end

  it "aggregates semantic errors from graph and scoring when the shape is valid" do
    d = valid_def
    d["steps"] << { "id" => "orphan", "prompt" => "Orphan?", "answer_type" => "boolean",
                    "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 1, "false" => 0 } }
    d["scoring"]["priority_map"] = { "media" => 5 }   # tier not in thresholds
    result = Protocols::Gate.call(d)
    expect(result.valid?).to be false
    expect(result.errors).to include("unreachable step: orphan")
    expect(result.errors).to include("priority_map tier 'media' not in thresholds")
  end
end
