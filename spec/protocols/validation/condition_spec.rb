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

  describe "gte/lte and reserved variables (ADR 0027)" do
    it "accepts gte/lte on an integer step and rejects them elsewhere" do
      expect(errs({ "gte" => ["idade", 60] })).to eq([])
      expect(errs({ "lte" => ["idade", 5] })).to eq([])
      expect(errs({ "gte" => ["febre", 1] })).to include(a_string_including("requires an integer step"))
      expect(errs({ "lte" => ["idade", "x"] })).to include("condition 'lte' threshold must be numeric")
    end

    it "rejects any reserved variable when the place allows none (decision_table, priority_when)" do
      expect(errs({ "gte" => ["profile.age", 60] })).to eq(["condition variable 'profile.age' is not allowed here"])
      expect(errs({ "eq" => ["outcome.tier", "alta"] })).to eq(["condition variable 'outcome.tier' is not allowed here"])
    end

    def place(node, variables) = described_class.errors(node, by_id, variables: variables)

    it "checks type and value of an allowed variable" do
      vars = %w[profile.age profile.sex outcome.tier outcome.score citizen.neighborhood_id]
      expect(place({ "gte" => ["profile.age", 60] }, vars)).to eq([])
      expect(place({ "in" => ["profile.sex", %w[female male]] }, vars)).to eq([])
      expect(place({ "eq" => ["outcome.tier", "qualquer"] }, vars)).to eq([])
      expect(place({ "in" => ["citizen.neighborhood_id", ["0b6f6c1e-9f1a-4d8b-9a4c-1f2e3d4c5b6a"]] }, vars)).to eq([])
      expect(place({ "eq" => ["profile.sex", "outro"] }, vars)).to eq(["condition 'eq' invalid value 'outro' for profile.sex"])
      expect(place({ "gt" => ["profile.sex", 1] }, vars)).to eq(["condition 'gt' requires a numeric variable, got profile.sex"])
      expect(place({ "in" => ["citizen.neighborhood_id", ["nao-uuid"]] }, vars))
        .to eq(["condition 'in' invalid value 'nao-uuid' for citizen.neighborhood_id"])
      expect(place({ "eq" => ["profile.age", "sessenta"] }, vars)).to eq(["condition 'eq' invalid value 'sessenta' for profile.age"])
      expect(place({ "gte" => ["profile.height", 1] }, vars)).to eq(["condition variable 'profile.height' is not allowed here"])
    end

    it "treats a reserved key in a legacy map as eq, and rejects empty all/any" do
      expect(place({ "profile.sex" => "female" }, %w[profile.sex])).to eq([])
      expect(place({ "profile.sex" => "x" }, %w[profile.sex])).to eq(["condition 'eq' invalid value 'x' for profile.sex"])
      expect(errs({ "all" => [] })).to eq(["condition 'all' operand must be a non-empty array"])
      expect(errs({ "any" => "x" })).to eq(["condition 'any' operand must be a non-empty array"])
    end
  end
end
