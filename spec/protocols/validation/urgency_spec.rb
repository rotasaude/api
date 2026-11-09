require "rails_helper"

# Módulo 32a (ADR 0050; contrato §3 e §14 Q1/Q3/Q16): a variante
# kind "urgency_classification". O schema (protocols-v1.7.0) cuida da forma
# — as 5 cores na ordem, os limites, o padrão do id —; o gate do api soma o id
# único (`rule_id`), os tempos fora de ordem (`levels_out_of_order`), as
# variáveis do `when` e o nome que já é de outro kind (`name_kind_conflict`).
RSpec.describe Protocols::Validation::Urgency do
  def definition(rules: UrgencyHelpers::RULES, levels: UrgencyHelpers::LEVELS, name: "classificacao-urgencia")
    { "name" => name, "version" => 1, "kind" => "urgency_classification",
      "levels" => levels.map(&:dup), "classification_rules" => rules.map(&:deep_dup) }
  end

  def rule(node, id: "regra", color: "red") = { "id" => id, "when" => node, "color" => color, "criterion" => "Critério" }

  def levels_with(color, minutes)
    UrgencyHelpers::LEVELS.map { |level| level["color"] == color ? level.merge("max_wait_minutes" => minutes) : level }
  end

  # contracts protocols-v1.7.0:protocols/examples/urgency-default.json, inteiro.
  def default_example = {
    "name" => "classificacao-urgencia", "version" => 1, "kind" => "urgency_classification",
    "levels" => [ { "color" => "red", "max_wait_minutes" => 0 }, { "color" => "orange", "max_wait_minutes" => 10 },
                  { "color" => "yellow", "max_wait_minutes" => 60 }, { "color" => "green", "max_wait_minutes" => 120 },
                  { "color" => "blue", "max_wait_minutes" => 240 } ],
    "classification_rules" => [
      { "id" => "spo2-baixa", "when" => { "lt" => [ "vitals.spo2", 90 ] }, "color" => "red",
        "criterion" => "Saturação de oxigênio abaixo de 90%" },
      { "id" => "pas-muito-alta", "when" => { "any" => [ { "gte" => [ "vitals.systolic", 220 ] }, { "lte" => [ "vitals.systolic", 80 ] } ] },
        "color" => "orange", "criterion" => "Pressão sistólica de 220 ou mais, ou de 80 ou menos" },
      { "id" => "dor-intensa", "when" => { "gte" => [ "pain_scale", 8 ] }, "color" => "orange", "criterion" => "Dor intensa (8 a 10)" },
      { "id" => "febre-alta", "when" => { "gte" => [ "vitals.temperature_c", 39.5 ] }, "color" => "yellow",
        "criterion" => "Temperatura de 39,5 °C ou mais" },
      { "id" => "idoso-dor-moderada", "when" => { "all" => [ { "gte" => [ "profile.age", 60 ] }, { "gte" => [ "pain_scale", 4 ] } ] },
        "color" => "yellow", "criterion" => "60 anos ou mais com dor moderada" },
      { "id" => "dor-leve", "when" => { "in" => [ "pain_scale", [ 1, 2, 3 ] ] }, "color" => "green", "criterion" => "Dor leve (1 a 3)" },
      { "id" => "sem-dor", "when" => { "not" => { "gt" => [ "pain_scale", 0 ] } }, "color" => "blue",
        "criterion" => "Sem dor e sinais vitais sem alerta" }
    ]
  }

  it "reconhece o kind" do
    expect(described_class.urgency?(definition)).to be(true)
    expect(described_class.urgency?({ "kind" => "screening" })).to be(false)
    expect(described_class.urgency?(nil)).to be(false)
  end

  it "definição válida (5 níveis em ordem, regras com pain_scale, vitals e perfil) → []" do
    extra = rule({ "all" => [ { "gte" => [ "profile.age", 60 ] }, { "eq" => [ "profile.sex", "female" ] },
                              { "eq" => [ "vitals.glucose_moment", "fasting" ] }, { "in" => [ "pain_scale", [ 1, 2 ] ] } ] },
                 id: "idosa_em_jejum", color: "blue")
    expect(described_class.call(definition(rules: UrgencyHelpers::RULES + [ extra ]))).to eq([])
    expect(described_class.call(default_example)).to eq([])
  end

  it "id repetido → rule_id, com o índice" do
    rules = UrgencyHelpers::RULES + [ UrgencyHelpers::RULES.first.merge("color" => "blue") ]
    errors = described_class.call(definition(rules: rules))
    expect(errors).to eq([ "rule_id: duplicate id 'spo2-critica' at classification_rules[4]" ])
  end

  it "tempo máximo que diminui na ordem de gravidade → levels_out_of_order, com o índice" do
    errors = described_class.call(definition(levels: levels_with("yellow", 5)))
    expect(errors).to eq([ "levels_out_of_order: levels[2] (yellow, 5 min) waits less than levels[1] (orange, 10 min)" ])
    expect(described_class.call(definition(levels: levels_with("orange", 0)))).to eq([]) # igual ao anterior vale
  end

  it "variáveis do when: só vitals.* (sem pain_score), pain_scale e profile.age/sex" do
    rules = [
      rule({ "gte" => [ "vitals.pain_score", 8 ] }, id: "a"), rule({ "eq" => [ "complaint.ciap2", "K86" ] }, id: "b"),
      rule({ "gte" => [ "outcome.score", 3 ] }, id: "c"), rule({ "eq" => [ "tosse", "true" ] }, id: "d"),
      rule({ "eq" => [ "citizen.neighborhood_id", SecureRandom.uuid ] }, id: "e"),
      rule({ "gte" => [ "vitals.spo2", 90 ] }, id: "f")
    ]
    errors = described_class.call(definition(rules: rules))
    expect(errors.size).to eq(5)
    expect(errors).to all(match(/\Aclassification_rules\[[0-4]\]\.when: /))
    expect(errors.join("\n")).to include("classification_rules[0].when: condition variable 'vitals.pain_score' is not allowed here",
                                         "classification_rules[1].when: condition variable 'complaint.ciap2' is not allowed here",
                                         "classification_rules[3].when: condition 'eq' references unknown step tosse")
  end

  it "total para lixo e para triagem" do
    expect(described_class.call(nil)).to eq([])
    expect(described_class.call({ "name" => "t", "steps" => [] })).to eq([])
    junk = definition.merge("levels" => "x", "classification_rules" => [ "x", { "id" => 1 } ])
    expect { described_class.call(junk) }.not_to raise_error
  end

  describe "Protocols::Gate" do
    it "aceita o exemplo padrão do contracts (schema da tag + gate)" do
      result = Protocols::Gate.call(default_example)
      expect([ result.valid?, result.errors ]).to eq([ true, [] ])
    end

    it "o schema da tag cuida da forma: cor fora de ordem, nível faltando, critério vazio, id com maiúscula" do
      swapped = definition.tap { |d| d["levels"][0], d["levels"][1] = d["levels"][1], d["levels"][0] }
      expect(Protocols::Gate.call(swapped).errors).to include("schema: /levels/0/color const")
      expect(Protocols::Gate.call(definition(levels: UrgencyHelpers::LEVELS.first(4))).errors)
        .to include("schema: /levels minItems")
      empty = definition(rules: [ UrgencyHelpers::RULES.first.merge("criterion" => "") ])
      expect(Protocols::Gate.call(empty).errors).to include("schema: /classification_rules/0/criterion minLength")
      upper = definition(rules: [ UrgencyHelpers::RULES.first.merge("id" => "Spo2") ])
      expect(Protocols::Gate.call(upper).errors).to include("schema: /classification_rules/0/id pattern")
      expect(Protocols::Gate.call(definition.merge("steps" => [])).errors).to include("schema: /steps schema")
    end

    it "o id do schema aceita sublinhado; o gate soma rule_id, levels_out_of_order e a variável" do
      expect(Protocols::Gate.call(definition(rules: [ rule({ "gte" => [ "pain_scale", 8 ] }, id: "dor_intensa") ])).valid?).to be(true)
      bad = definition(rules: [ rule({ "gte" => [ "vitals.pain_score", 8 ] }, id: "x"), rule({ "lt" => [ "vitals.spo2", 90 ] }, id: "x") ],
                       levels: levels_with("blue", 100))
      errors = Protocols::Gate.call(bad).errors
      expect(errors.map { |e| e.split(":").first }).to contain_exactly("levels_out_of_order", "rule_id", "classification_rules[0].when")
    end

    it "nome de outro kind → name_kind_conflict, nos dois sentidos (Q16)" do
      ProtocolDefinition.create!(name: "dengue", version: 1, status: "draft", definition: protocol_definition_hash(name: "dengue"))
      expect(Protocols::Gate.call(definition(name: "dengue")).errors)
        .to eq([ "name_kind_conflict: name 'dengue' is used by a protocol of another kind" ])

      ProtocolDefinition.create!(name: "classificacao-urgencia", version: 1, status: "draft", definition: definition)
      expect(Protocols::Gate.call(protocol_definition_hash(name: "classificacao-urgencia")).errors)
        .to eq([ "name_kind_conflict: name 'classificacao-urgencia' is used by a protocol of another kind" ])
      # A mesma linha (ou outra versão do mesmo protocolo) não conflita consigo.
      expect(Protocols::Gate.call(definition.merge("version" => 2)).valid?).to be(true)
    end
  end

  describe "Protocols::Validator (save do rascunho)" do
    it "exige só a forma mínima: name, version, levels e classification_rules arrays" do
      expect(Protocols::Validator.call(definition).valid?).to be(true)
      expect(Protocols::Validator.call(definition.except("classification_rules")).errors).to eq([ "missing :classification_rules" ])
      expect(Protocols::Validator.call(definition.merge("levels" => "x")).errors).to eq([ "missing :levels" ])
      expect(Protocols::Validator.call(definition.merge("levels" => [])).valid?).to be(true) # rascunho: o gate decide
    end
  end
end
