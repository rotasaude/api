require "rails_helper"

RSpec.describe Protocols::Validator do
  def base
    {
      "name" => "triagem-teste",
      "version" => 1,
      "start_step_id" => "s1",
      "steps" => [
        { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
          "branches" => { "true" => nil, "false" => nil } }
      ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "alta" => 5 } }
    }
  end

  it "is valid without recommendations" do
    expect(Protocols::Validator.call(base)).to be_valid
  end

  it "is valid when recommendation keys match declared weighted tiers" do
    d = base.merge("recommendations" => {
      "baixa" => { "title" => "T", "body" => "B" },
      "alta"  => { "title" => "T", "body" => "B" }
    })
    expect(Protocols::Validator.call(d)).to be_valid
  end

  it "rejects a recommendation for an undeclared tier" do
    d = base.merge("recommendations" => { "media" => { "title" => "T", "body" => "B" } })
    result = Protocols::Validator.call(d)
    expect(result).not_to be_valid
    expect(result.errors.join).to include("unknown tier media")
  end

  it "collects decision_table tiers from rules and fallback" do
    d = base.merge(
      "scoring" => {
        "type" => "decision_table",
        "rules" => [{ "when" => { "s1" => "true" }, "tier" => "urgente", "priority" => 1 }],
        "fallback" => { "tier" => "rotina", "priority" => 9 }
      },
      "recommendations" => {
        "urgente" => { "title" => "T", "body" => "B" },
        "rotina"  => { "title" => "T", "body" => "B" }
      }
    )
    expect(Protocols::Validator.call(d)).to be_valid
  end
end
