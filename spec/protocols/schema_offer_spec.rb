# spec/protocols/schema_offer_spec.rb
require "rails_helper"
require "json_schemer"

# protocols-v1.4.0 (ADR 0027; contratos §1): offer e suggestions opcionais;
# gte/lte em toda condição. A cópia em config/protocols/schema.json é idêntica
# à do contracts.
RSpec.describe "protocols schema.json offer/suggestions contract (v1.4.0)" do
  let(:schema) { JSONSchemer.schema(JSON.parse(File.read(Rails.root.join("config/protocols/schema.json")))) }

  def base(extra = {})
    {
      "name" => "saude-do-idoso", "version" => 1, "start_step_id" => "s1",
      "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "integer", "branches" => {}, "weights" => {} } ],
      "scoring" => { "type" => "weighted", "thresholds" => { "baixa" => 0 }, "priority_map" => { "baixa" => 9 } }
    }.merge(extra)
  end

  it "aceita protocolo sem offer nem suggestions (1.3.0 continua válido)" do
    expect(schema.valid?(base)).to be(true)
  end

  it "aceita offer completo e suggestions com gte/lte" do
    definition = base(
      "offer" => { "title" => "Saúde do idoso", "summary" => "Avaliação anual.",
                   "eligibility" => { "gte" => ["profile.age", 60] }, "retake_after_days" => 365 },
      "suggestions" => [ { "protocol" => "saude-mental-aprofundada", "when" => { "lte" => ["outcome.score", 3] } } ]
    )
    expect(schema.valid?(definition)).to be(true)
  end

  it "aceita gte/lte também em priority_when" do
    definition = base("priority_when" => [ { "when" => { "gte" => ["s1", 3] }, "priority" => 2 } ])
    expect(schema.valid?(definition)).to be(true)
  end

  it "recusa campo desconhecido, título longo, intervalo zero e nome de sugestão fora do padrão do name" do
    expect(schema.valid?(base("offer" => { "audience" => "todos" }))).to be(false)
    expect(schema.valid?(base("offer" => { "title" => "x" * 61 }))).to be(false)
    expect(schema.valid?(base("offer" => { "summary" => "x" * 201 }))).to be(false)
    expect(schema.valid?(base("offer" => { "retake_after_days" => 0 }))).to be(false)
    expect(schema.valid?(base("offer" => { "retake_after_days" => 3651 }))).to be(false)
    expect(schema.valid?(base("suggestions" => [ { "protocol" => "9-comeca-com-digito", "when" => { "eq" => ["s1", "1"] } } ]))).to be(false)
    expect(schema.valid?(base("suggestions" => [ { "protocol" => "Maiuscula", "when" => { "eq" => ["s1", "1"] } } ]))).to be(false)
    expect(schema.valid?(base("suggestions" => [ { "protocol" => "x" } ]))).to be(false)
    expect(schema.valid?(base("suggestions" => Array.new(11) { { "protocol" => "outro", "when" => { "eq" => ["s1", "1"] } } }))).to be(false)
  end
end
