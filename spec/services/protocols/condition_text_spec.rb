require "rails_helper"

# Contratos §4.3: frase gerada no api só para conferência (a da tela é do
# construtor do dashboard). Total: árvore inválida vira "regra inválida".
RSpec.describe Protocols::ConditionText do
  it "escreve as condições do catálogo em português" do
    {
      nil => "todos",
      { "gte" => ["profile.age", 60] } => "idade ≥ 60",
      { "all" => [ { "gte" => ["profile.age", 60] }, { "eq" => ["profile.sex", "female"] } ] } => "idade ≥ 60 e sexo = feminino",
      { "any" => [ { "all" => [ { "gte" => ["profile.age", 60] }, { "lte" => ["profile.age", 79] } ] },
                   { "eq" => ["profile.sex", "male"] } ] } => "(idade ≥ 60 e idade ≤ 79) ou sexo = masculino",
      { "not" => { "lt" => ["profile.age", 18] } } => "não (idade < 18)",
      { "in" => ["citizen.neighborhood_id", %w[a b]] } => "bairro em a, b",
      { "gte" => ["outcome.score", 15] } => "pontuação ≥ 15",
      { "eq" => ["humor", "true"] } => "resposta de humor = true",
      { "profile.sex" => "female" } => "sexo = feminino"
    }.each { |node, text| expect(described_class.call(node)).to eq(text), node.inspect }
  end

  it "árvore inválida vira 'regra inválida', sem levantar" do
    [ "x", {}, { "all" => { "xyz" => 1, "abc" => 2 } }, { "gte" => "x" }, { "any" => [] } ].each do |node|
      expect(described_class.call(node)).to eq("regra inválida"), node.inspect
    end
  end
end
