require "rails_helper"
require "json_schemer"

RSpec.describe "protocols schema.json priority_when contract (F-03.6)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def base(priority_when)
    {
      "name" => "pw-contract", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => {}, "weights" => {} }],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 5 } },
      "priority_when" => priority_when
    }
  end

  it "accepts priority_when with a condition-DSL when" do
    expect(schema.valid?(base([{ "when" => { "gt" => ["s1", 80] }, "priority" => 1 }]))).to be(true)
  end

  it "accepts priority_when with a legacy flat when" do
    expect(schema.valid?(base([{ "when" => { "s1" => "true" }, "priority" => 2 }]))).to be(true)
  end

  it "rejects a priority out of range" do
    expect(schema.valid?(base([{ "when" => { "s1" => "true" }, "priority" => 10 }]))).to be(false)
  end
end
