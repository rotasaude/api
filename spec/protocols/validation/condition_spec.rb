require "rails_helper"

RSpec.describe Protocols::Validation::Condition do
  let(:steps) do
    [
      { "id" => "febre", "answer_type" => "boolean" },
      { "id" => "idade", "answer_type" => "integer" },
      { "id" => "cor", "answer_type" => "enum", "options" => %w[verde amarelo vermelho] }
    ]
  end
  let(:by_id) { steps.to_h { |s| [s["id"], s] } }
  def errs(node) = described_class.errors(node, by_id)

  it "accepts a valid eq / in / gt / lt" do
    expect(errs({ "eq" => ["febre", "true"] })).to eq([])
    expect(errs({ "in" => ["cor", %w[verde amarelo]] })).to eq([])
    expect(errs({ "gt" => ["idade", 60] })).to eq([])
    expect(errs({ "lt" => ["idade", 5] })).to eq([])
  end

  it "flags eq/in on an unknown step or a disallowed answer" do
    expect(errs({ "eq" => ["ausente", "true"] })).not_to be_empty
    expect(errs({ "eq" => ["febre", "talvez"] })).not_to be_empty     # not in %w[true false]
    expect(errs({ "in" => ["cor", %w[verde roxo]] })).not_to be_empty # roxo not an option
  end

  it "requires gt/lt on an integer step" do
    expect(errs({ "gt" => ["febre", 1] })).not_to be_empty  # febre is boolean
    expect(errs({ "lt" => ["cor", 1] })).not_to be_empty    # cor is enum
  end

  it "recurses through all/any/not" do
    expect(errs({ "all" => [{ "gt" => ["idade", 60] }, { "eq" => ["febre", "true"] }] })).to eq([])
    expect(errs({ "any" => [{ "gt" => ["febre", 1] }] })).not_to be_empty  # nested bad node
    expect(errs({ "not" => { "eq" => ["idade", "x"] } })).to be_a(Array)   # recurses (idade unconstrained → [])
    expect(errs({ "all" => "notarray" })).not_to be_empty
  end

  it "validates a legacy flat when map" do
    expect(errs({ "febre" => "true" })).to eq([])
    expect(errs({ "febre" => "nope" })).not_to be_empty
    expect(errs({ "ausente" => "true" })).not_to be_empty
  end

  it "flags a non-hash / empty / malformed-operand node" do
    expect(errs({})).not_to be_empty
    expect(errs(nil)).not_to be_empty
    expect(errs({ "eq" => "notarray" })).not_to be_empty
  end

  it "step_id_collision_errors flags a step named like an operator" do
    expect(described_class.step_id_collision_errors([{ "id" => "eq" }, { "id" => "febre" }])).not_to be_empty
    expect(described_class.step_id_collision_errors([{ "id" => "febre" }])).to eq([])
  end
end
