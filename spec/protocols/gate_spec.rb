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

  def dt_def(rule_when)
    {
      "name" => "dt", "version" => 1, "start_step_id" => "idade",
      "steps" => [{ "id" => "idade", "prompt" => "Idade?", "answer_type" => "integer", "branches" => {} }],
      "scoring" => { "type" => "decision_table",
                     "rules" => [{ "when" => rule_when, "tier" => "alta", "priority" => 1 }],
                     "fallback" => { "tier" => "baixa", "priority" => 9 } }
    }
  end

  it "accepts a valid condition-DSL when (regression: was wrongly rejected before)" do
    result = Protocols::Gate.call(dt_def({ "gt" => ["idade", 60] }))
    expect(result.valid?).to be(true), result.errors.inspect
  end

  it "rejects gt/lt on a non-integer step" do
    d = dt_def({ "gt" => ["idade", 60] })
    d["steps"][0]["answer_type"] = "boolean"
    d["steps"][0]["branches"] = { "true" => nil, "false" => nil }
    result = Protocols::Gate.call(d)
    expect(result.valid?).to be(false)
    expect(result.errors.join).to match(/integer step/)
  end

  it "rejects an eq with a disallowed answer" do
    d = dt_def({ "eq" => ["grave", "sim"] })
    d["steps"] << { "id" => "grave", "prompt" => "Grave?", "answer_type" => "boolean", "branches" => { "true" => nil, "false" => nil } }
    result = Protocols::Gate.call(d)
    expect(result.valid?).to be(false)
    expect(result.errors.join).to match(/invalid answer 'sim' for step grave/)
  end

  it "rejects a step named like an operator" do
    d = dt_def({ "gt" => ["idade", 60] })
    d["steps"] << { "id" => "any", "prompt" => "?", "answer_type" => "boolean", "branches" => { "true" => nil, "false" => nil } }
    result = Protocols::Gate.call(d)
    expect(result.valid?).to be(false)
    expect(result.errors.join).to match(/collides with a condition operator/)
  end

  it "still accepts a legacy flat when" do
    d = dt_def({ "idade" => "60" })
    expect(Protocols::Gate.call(d).valid?).to be(true), Protocols::Gate.call(d).errors.inspect
  end

  describe "offer and suggestions (ADR 0027)" do
    let(:base) do
      {
        "name" => "saude-do-idoso", "version" => 1, "start_step_id" => "quedas",
        "steps" => [ { "id" => "quedas", "prompt" => "Caiu no último ano?", "answer_type" => "boolean",
                       "branches" => { "true" => nil, "false" => nil }, "weights" => { "true" => 3, "false" => 0 } } ],
        "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0, "media" => 3 },
                       "priority_map" => { "baixa" => 9, "media" => 5 } }
      }
    end

    it "aceita oferta e sugestão válidas" do
      definition = base.merge(
        "offer" => { "title" => "Saúde do idoso", "eligibility" => { "gte" => ["profile.age", 60] }, "retake_after_days" => 365 },
        "suggestions" => [ { "protocol" => "saude-mental", "when" => { "eq" => ["quedas", "true"] } } ]
      )
      expect(Protocols::Gate.call(definition)).to be_valid
    end

    it "recusa variável fora do lugar, sugestão para si e intervalo zero" do
      result = Protocols::Gate.call(base.merge(
        "offer" => { "eligibility" => { "gte" => ["outcome.score", 1] } },
        "suggestions" => [ { "protocol" => "saude-do-idoso", "when" => { "eq" => ["quedas", "true"] } } ]
      ))
      expect(result.errors).to include(
        "offer.eligibility: condition variable 'outcome.score' is not allowed here",
        "suggestions[0]: suggestion points to the protocol itself"
      )
      expect(Protocols::Gate.call(base.merge("offer" => { "retake_after_days" => 0 }))).not_to be_valid
    end

    it "recusa id de passo com prefixo reservado e variável reservada em priority_when" do
      steps = [ base["steps"].first.merge("id" => "profile.age") ]
      result = Protocols::Gate.call(base.merge("steps" => steps, "start_step_id" => "profile.age"))
      expect(result.errors).to include("step id 'profile.age' uses a reserved prefix (profile., outcome., citizen.)")
      result = Protocols::Gate.call(base.merge("priority_when" => [ { "when" => { "gte" => ["profile.age", 60] }, "priority" => 2 } ]))
      expect(result.errors).to include("condition variable 'profile.age' is not allowed here")
    end
  end
end
