require "rails_helper"

# Desvio 10 e contrato §14 Q1/Q3: a sugestão é pura sobre a definição; a dor
# é `pain_scale` (fora de vitals), a queixa nunca entra, vale a cor mais grave
# entre as regras que casam e, no empate, a primeira da lista.
RSpec.describe Urgency::Suggest do
  def protocol(rules = UrgencyHelpers::RULES)
    ProtocolDefinition.new(definition: { "kind" => "urgency_classification", "levels" => UrgencyHelpers::LEVELS,
                                         "classification_rules" => rules })
  end

  it "a mais grave entre as que casam, com o critério e a regra" do
    expect(described_class.call(vitals: { "spo2" => 88, "temperature_c" => BigDecimal("39.5") }, pain_scale: 9, profile: {},
                                protocol: protocol))
      .to eq(color: "red", criterion: "SpO2 abaixo de 90%", rule_id: "spo2-critica")
    expect(described_class.call(vitals: { "spo2" => 98 }, pain_scale: 9, profile: {}, protocol: protocol))
      .to eq(color: "orange", criterion: "Dor intensa (8 a 10)", rule_id: "dor-intensa")
    expect(described_class.call(vitals: {}, pain_scale: 5, profile: {}, protocol: protocol))
      .to eq(color: "green", criterion: "Dor moderada (4 a 7)", rule_id: "dor-moderada")
  end

  it "nada casa → nil; sem protocolo → nil; pain_score dentro de vitals é ignorado" do
    expect(described_class.call(vitals: { "spo2" => 98 }, pain_scale: 0, profile: {}, protocol: protocol)).to be_nil
    expect(described_class.call(vitals: { "spo2" => 80 }, pain_scale: 0, profile: {}, protocol: nil)).to be_nil
    expect(described_class.call(vitals: { "pain_score" => 10 }, pain_scale: 0, profile: {}, protocol: protocol)).to be_nil
    pain_score_rule = [ { "id" => "x", "when" => { "gte" => [ "vitals.pain_score", 1 ] }, "color" => "red", "criterion" => "X" } ]
    expect(described_class.call(vitals: { "pain_score" => 10 }, pain_scale: 10, profile: {}, protocol: protocol(pain_score_rule)))
      .to be_nil
  end

  it "empate de cor: a primeira regra da lista; in e eq sobre pain_scale; perfil; pain_scale nulo não entra" do
    rules = [
      { "id" => "leve", "when" => { "in" => [ "pain_scale", [ 1, 2, 3 ] ] }, "color" => "green", "criterion" => "Leve" },
      { "id" => "idosa", "when" => { "all" => [ { "gte" => [ "profile.age", 60 ] }, { "eq" => [ "profile.sex", "female" ] } ] },
        "color" => "green", "criterion" => "Idosa" },
      { "id" => "nenhuma", "when" => { "eq" => [ "pain_scale", 0 ] }, "color" => "blue", "criterion" => "Sem dor" }
    ]
    expect(described_class.call(vitals: {}, pain_scale: 2, profile: { age: 70, sex: "female" }, protocol: protocol(rules)))
      .to eq(color: "green", criterion: "Leve", rule_id: "leve")
    expect(described_class.call(vitals: {}, pain_scale: 5, profile: { age: 70, sex: "female" }, protocol: protocol(rules)))
      .to eq(color: "green", criterion: "Idosa", rule_id: "idosa")
    expect(described_class.call(vitals: {}, pain_scale: 0, profile: {}, protocol: protocol(rules))[:rule_id]).to eq("nenhuma")
    expect(described_class.call(vitals: {}, pain_scale: nil, profile: {}, protocol: protocol(rules))).to be_nil
  end

  it "sem protocolo dado, lê o ativo da cidade" do
    expect(described_class.call(vitals: { "spo2" => 80 }, pain_scale: 0, profile: {})).to be_nil
    urgency_protocol!
    expect(described_class.call(vitals: { "spo2" => 80 }, pain_scale: 0, profile: {})[:rule_id]).to eq("spo2-critica")
  end
end

RSpec.describe Urgency::Levels do
  it "os tempos máximos do protocolo, na ordem das cores; sem protocolo, o padrão" do
    v2 = ProtocolDefinition.new(definition: { "levels" => UrgencyHelpers::LEVELS.map { |l| l["color"] == "yellow" ? l.merge("max_wait_minutes" => 30) : l } })
    expect(described_class.for(v2)).to eq("red" => 0, "orange" => 10, "yellow" => 30, "green" => 120, "blue" => 240)
    expect(described_class.for(v2).keys).to eq(Urgency::Catalog::COLORS)
    expect(described_class.for(nil)).to eq(Urgency::Catalog::DEFAULT_MAX_WAIT)
  end
end
