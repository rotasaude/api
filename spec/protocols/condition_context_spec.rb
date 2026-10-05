require "rails_helper"

# ADR 0027 (spec 2026-10-05 §4.1): o contexto plano junta respostas e variáveis
# reservadas. Valores reservados viram texto (eq/in comparam texto; gt/gte
# convertem com Float), nil some (variável ausente → falso), e uma resposta com
# id de prefixo reservado nunca sobrescreve a variável.
RSpec.describe Protocols::ConditionContext do
  it "builds a flat context with stringified reserved variables" do
    context = described_class.build(
      answers: { "q1" => "true", "profile.age" => "999" },
      profile: { age: 62, sex: "female" },
      outcome: { tier: "media", score: 15, priority: 5 },
      citizen: { neighborhood_id: "0b6f6c1e-9f1a-4d8b-9a4c-1f2e3d4c5b6a" }
    )
    expect(context).to eq(
      "q1" => "true", "profile.age" => "62", "profile.sex" => "female",
      "outcome.tier" => "media", "outcome.score" => "15", "outcome.priority" => "5",
      "citizen.neighborhood_id" => "0b6f6c1e-9f1a-4d8b-9a4c-1f2e3d4c5b6a"
    )
  end

  it "drops nil values and accepts string keys" do
    context = described_class.build(profile: { "age" => nil, "sex" => "male" }, outcome: nil, citizen: "x")
    expect(context).to eq("profile.sex" => "male")
  end

  it "knows the reserved prefixes" do
    expect(described_class.reserved?("profile.age")).to be(true)
    expect(described_class.reserved?("outcome.x")).to be(true)
    expect(described_class.reserved?("citizen.neighborhood_id")).to be(true)
    expect(described_class.reserved?("profiles")).to be(false)
  end
end
