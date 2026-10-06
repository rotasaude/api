require "rails_helper"
require "json_schemer"

# protocols-v1.5.0 (ADR 0029; contratos §1, §8): scheduling opcional, até 10
# regras, `when` só na forma estruturada.
RSpec.describe "protocols schema.json scheduling contract (v1.5.0)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def base(extra = {})
    {
      "name" => "saude-do-idoso", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "integer", "branches" => {}, "weights" => {} } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }.merge(extra)
  end

  def rule(extra = {})
    { "when" => { "gte" => ["outcome.score", 3] }, "appointment_type" => "consulta_medica",
      "priority" => "routine", "due_in_days" => 30 }.merge(extra)
  end

  it "aceita protocolo sem scheduling (1.4.0 continua válido) e com regras completas" do
    expect(schema.valid?(base)).to be(true)
    expect(schema.valid?(base("scheduling" => [ rule, rule("priority" => "priority", "due_in_days" => 1) ]))).to be(true)
  end

  it "recusa campo faltando, prioridade, prazo, tipo e mapa simples no when" do
    expect(schema.valid?(base("scheduling" => [ rule.except("due_in_days") ]))).to be(false)
    expect(schema.valid?(base("scheduling" => [ rule("priority" => "urgent") ]))).to be(false)
    expect(schema.valid?(base("scheduling" => [ rule("due_in_days" => 0) ]))).to be(false)
    expect(schema.valid?(base("scheduling" => [ rule("due_in_days" => 366) ]))).to be(false)
    expect(schema.valid?(base("scheduling" => [ rule("appointment_type" => "Consulta") ]))).to be(false)
    expect(schema.valid?(base("scheduling" => [ rule("when" => { "s1" => "1" }) ]))).to be(false)
    expect(schema.valid?(base("scheduling" => [ rule("extra" => 1) ]))).to be(false)
    expect(schema.valid?(base("scheduling" => Array.new(11) { rule }))).to be(false)
  end
end
