require "rails_helper"
require "json_schemer"

RSpec.describe "protocols schema.json condition contract (F-03.2)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def base(rule_when)
    {
      "name" => "cond-contract", "version" => 1, "start_step_id" => "s1",
      "steps" => [{ "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                    "branches" => {}, "weights" => {} }],
      "scoring" => { "type" => "decision_table",
                     "rules" => [{ "when" => rule_when, "tier" => "alta", "priority" => 1 }],
                     "fallback" => { "tier" => "baixa", "priority" => 9 } }
    }
  end

  it "accepts a legacy flat when map" do
    expect(schema.valid?(base({ "s1" => "true" }))).to be(true)
  end

  it "accepts a condition-DSL when node" do
    expect(schema.valid?(base({ "any" => [{ "gt" => ["s1", 60] }, { "eq" => ["s1", "true"] }] }))).to be(true)
  end

  it "accepts nested all/not" do
    expect(schema.valid?(base({ "all" => [{ "not" => { "eq" => ["s1", "false"] } }] }))).to be(true)
  end
end
