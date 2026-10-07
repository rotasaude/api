require "rails_helper"
require "json_schemer"

# protocols-v1.6.0 (ADR 0030; contratos §1): variante kind "screening".
RSpec.describe "protocols schema.json screening contract (v1.6.0)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def screening(extra = {})
    { "name" => "acolhimento", "version" => 1, "kind" => "screening",
      "risk_rules" => [ { "when" => { "gte" => ["vitals.systolic", 180] }, "color" => "red" } ] }.merge(extra)
  end

  it "aceita a variante e continua aceitando triagem sem kind" do
    expect(schema.valid?(screening)).to be(true)
    triage = { "name" => "triagem-x", "version" => 1, "start_step_id" => "s1",
               "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean" } ] }
    expect(schema.valid?(triage)).to be(true)
  end

  it "recusa cor fora da escala, regras vazias ou demais, campos de triagem e regra sem when" do
    expect(schema.valid?(screening("risk_rules" => [ { "when" => { "gte" => ["vitals.spo2", 1] }, "color" => "orange" } ]))).to be(false)
    expect(schema.valid?(screening("risk_rules" => []))).to be(false)
    expect(schema.valid?(screening("risk_rules" => Array.new(51) { { "when" => { "gte" => ["vitals.spo2", 1] }, "color" => "blue" } }))).to be(false)
    expect(schema.valid?(screening("steps" => []))).to be(false)
    expect(schema.valid?(screening("scoring" => {}))).to be(false)
    expect(schema.valid?(screening("start_step_id" => "s1"))).to be(false)
    expect(schema.valid?(screening("recommendations" => {}))).to be(false)
    expect(schema.valid?(screening("priority_when" => []))).to be(false)
    expect(schema.valid?(screening("schema_version" => 6))).to be(true)
    expect(schema.valid?(screening("schema_version" => "1.6.0"))).to be(false)
    expect(schema.valid?(screening("risk_rules" => [ { "color" => "red" } ]))).to be(false)
    expect(schema.valid?(screening.except("risk_rules"))).to be(false)
  end
end
