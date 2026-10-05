# spec/protocols/validation/offer_spec.rb
require "rails_helper"

# ADR 0027 (spec 2026-10-05 §4.3; contratos §1): cada lugar aceita só as suas
# variáveis; sugestão nunca aponta para o próprio protocolo.
RSpec.describe Protocols::Validation::Offer do
  def definition(offer: nil, suggestions: nil)
    {
      "name" => "saude-mental", "version" => 1, "start_step_id" => "humor",
      "steps" => [ { "id" => "humor", "prompt" => "?", "answer_type" => "integer" },
                   { "id" => "sono", "prompt" => "?", "answer_type" => "boolean" } ],
      "offer" => offer, "suggestions" => suggestions
    }.compact
  end

  it "aceita elegibilidade de perfil e sugestão sobre perfil, resultado e passos" do
    errors = described_class.call(definition(
      offer: { "eligibility" => { "all" => [ { "gte" => ["profile.age", 18] }, { "eq" => ["profile.sex", "female"] } ] } },
      suggestions: [ { "protocol" => "saude-mental-aprofundada",
                       "when" => { "any" => [ { "gte" => ["outcome.score", 15] }, { "eq" => ["sono", "false"] },
                                              { "gte" => ["humor", 7] }, { "eq" => ["outcome.tier", "alta"] } ] } } ]
    ))
    expect(errors).to eq([])
  end

  it "recusa na elegibilidade resultado, bairro e passo" do
    errors = described_class.call(definition(offer: { "eligibility" => { "any" => [
      { "gte" => ["outcome.score", 1] }, { "in" => ["citizen.neighborhood_id", []] }, { "eq" => ["sono", "true"] }
    ] } }))
    expect(errors).to eq([
      "offer.eligibility: condition variable 'outcome.score' is not allowed here",
      "offer.eligibility: condition variable 'citizen.neighborhood_id' is not allowed here",
      "offer.eligibility: condition 'eq' references unknown step sono"
    ])
  end

  it "recusa na sugestão bairro, passo inexistente e o próprio protocolo" do
    errors = described_class.call(definition(suggestions: [
      { "protocol" => "saude-mental", "when" => { "gte" => ["outcome.score", 1] } },
      { "protocol" => "outro", "when" => { "in" => ["citizen.neighborhood_id", []] } },
      { "protocol" => "outro", "when" => { "eq" => ["fantasma", "1"] } }
    ]))
    expect(errors).to eq([
      "suggestions[0]: suggestion points to the protocol itself",
      "suggestions[1].when: condition variable 'citizen.neighborhood_id' is not allowed here",
      "suggestions[2].when: condition 'eq' references unknown step fantasma"
    ])
  end

  it "recusa intervalo de repetição que não é inteiro positivo" do
    expect(described_class.call(definition(offer: { "retake_after_days" => 0 })))
      .to eq(["offer.retake_after_days must be a positive integer"])
    expect(described_class.call(definition(offer: { "retake_after_days" => "365" })))
      .to eq(["offer.retake_after_days must be a positive integer"])
  end

  it "é total para qualquer entrada" do
    [ nil, {}, { "offer" => "x" }, { "suggestions" => "x" }, { "suggestions" => [ "x", nil ] },
      { "steps" => "x", "suggestions" => [ { "protocol" => "a", "when" => "x" } ] } ].each do |input|
      expect { described_class.call(input) }.not_to raise_error, input.inspect
    end
  end
end
