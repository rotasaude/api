require "rails_helper"

RSpec.describe Protocols::Validation::Schema do
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

  it "accepts a valid definition" do
    expect(Protocols::Validation::Schema.call(valid_def)).to eq([])
  end

  it "rejects an invalid answer_type" do
    d = valid_def
    d["steps"][0]["answer_type"] = "color"
    expect(Protocols::Validation::Schema.call(d)).not_to be_empty
  end

  it "rejects a priority outside 1..9" do
    d = valid_def
    d["scoring"]["priority_map"]["baixa"] = 99
    expect(Protocols::Validation::Schema.call(d)).not_to be_empty
  end

  it "rejects an unknown top-level property (additionalProperties: false)" do
    expect(Protocols::Validation::Schema.call(valid_def.merge("bogus" => true))).not_to be_empty
  end
end
