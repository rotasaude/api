require "rails_helper"

# ADR 0030 (spec §3.3): o when das regras de cor aceita vitals.*, complaint.ciap2
# e profile.*; o nome acolhimento é reservado à variante.
RSpec.describe Protocols::Validation::Screening do
  def definition(rules, name: "acolhimento")
    { "name" => name, "version" => 1, "kind" => "screening", "risk_rules" => rules }
  end

  def rule(node, color = "red") = { "when" => node, "color" => color }

  it "aceita sinais, queixa e perfil, inclusive momento da glicemia" do
    node = { "any" => [ { "gte" => ["vitals.systolic", 180] }, { "lt" => ["vitals.spo2", 90] },
                        { "eq" => ["complaint.ciap2", "K86"] }, { "eq" => ["vitals.glucose_moment", "fasting"] },
                        { "gte" => ["profile.age", 60] }, { "eq" => ["profile.sex", "female"] },
                        { "gte" => ["vitals.bmi", 40] } ] }
    expect(described_class.call(definition([ rule(node) ]))).to eq([])
  end

  it "recusa variável de outro lugar, valores inválidos, passo e regra malformada" do
    errors = described_class.call(definition([
      rule({ "gte" => ["outcome.score", 3] }), rule({ "eq" => ["complaint.ciap2", "k86"] }),
      rule({ "eq" => ["vitals.glucose_moment", "noite"] }), rule({ "gte" => ["vitals.glucose_moment", 1] }),
      rule({ "eq" => ["tosse", "true"] }), "x", { "when" => { "gte" => ["vitals.spo2", 1] }, "color" => "orange" }
    ]))
    expect(errors.join("\n")).to include("risk_rules[0].when", "risk_rules[1].when", "risk_rules[2].when",
                                         "risk_rules[3].when", "risk_rules[4].when", "risk_rules[5] must be an object",
                                         "risk_rules[6].color")
  end

  it "nome reservado: screening só com acolhimento; triagem nunca com acolhimento" do
    expect(described_class.call(definition([ rule({ "gte" => ["vitals.spo2", 1] }) ], name: "outro")))
      .to include("screening protocol must be named 'acolhimento'")
    expect(described_class.reserved_name_errors({ "name" => "acolhimento", "steps" => [] }))
      .to eq([ "name 'acolhimento' is reserved for the screening protocol" ])
  end

  it "total para lixo e para triagem" do
    expect(described_class.call(nil)).to eq([])
    expect(described_class.call({ "name" => "t" })).to eq([])
    expect(described_class.call(definition("x"))).to eq([ "risk_rules must be an array" ])
    expect(described_class.call(definition([]))).to eq([ "risk_rules must have 1 to 50 rules" ])
  end

  it "o gate completo responde à variante sem rodar os linters de triagem" do
    result = Protocols::Gate.call(definition([ rule({ "gte" => ["vitals.systolic", 180] }) ]))
    expect(result.valid?).to be(true)
    expect(Protocols::Gate.call(definition([ rule({ "gte" => ["outcome.score", 1] }) ])).valid?).to be(false)
  end

  it "o validador do save aceita a variante (rascunho) e recusa sem risk_rules" do
    expect(Protocols::Validator.call(definition([ rule({ "gte" => ["vitals.spo2", 1] }) ])).valid?).to be(true)
    expect(Protocols::Validator.call(definition(nil).except("risk_rules")).errors).to include("missing :risk_rules")
  end
end
