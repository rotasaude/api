require "rails_helper"
require "json_schemer"

# F-14.6 (ADR 0025; spec 2026-09-30 §7): a marca `analytic` é da pergunta, só
# em boolean/enum, e o portão do ciclo assinado recusa o resto.
RSpec.describe "protocols schema.json analytic contract (F-14.6)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def definition(step)
    {
      "name" => "arbo-contract", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "branches" => {}, "weights" => {} }.merge(step) ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }
  end

  it "aceita analytic em boolean e em enum, e analytic: false em qualquer tipo" do
    expect(schema.valid?(definition("answer_type" => "boolean", "analytic" => true))).to be(true)
    expect(schema.valid?(definition("answer_type" => "enum", "options" => %w[a b], "analytic" => true))).to be(true)
    expect(schema.valid?(definition("answer_type" => "integer", "analytic" => false))).to be(true)
    expect(schema.valid?(definition("answer_type" => "text"))).to be(true)
  end

  it "recusa analytic: true em integer e em text, e analytic que não é booleano" do
    expect(schema.valid?(definition("answer_type" => "integer", "analytic" => true))).to be(false)
    expect(schema.valid?(definition("answer_type" => "text", "analytic" => true))).to be(false)
    expect(schema.valid?(definition("answer_type" => "boolean", "analytic" => "sim"))).to be(false)
  end

  it "o portão do ciclo assinado aponta a pergunta marcada errada" do
    errors = Protocols::Gate.call(definition("answer_type" => "integer", "analytic" => true)).errors
    expect(errors).to include(a_string_including("/steps/0/answer_type"))
    expect(Protocols::Gate.call(definition("answer_type" => "boolean", "analytic" => true,
                                           "branches" => { "true" => nil, "false" => nil })).errors).to be_empty
  end
end
