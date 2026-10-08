require "rails_helper"

# ADR 0031 (contratos §2 e §9): com a chave, nome completo 3–200 obrigatório;
# social e mãe opcionais até 200; sem a chave (cliente antigo), nada a gravar.
RSpec.describe Citizens::NameValues do
  def call(**names) = described_class.call(full_name: "Maria Aparecida da Silva", **names)

  it "normaliza e aceita opcionais vazios" do
    result = call(full_name: "  Maria   Aparecida  da Silva ", social_name: " ", mother_name: "Joana  da Silva")
    expect(result.payload).to eq(full_name: "Maria Aparecida da Silva", social_name: nil, mother_name: "Joana da Silva")
  end

  it "sem a chave: ok e nada a gravar (mesmo com social ou mãe)" do
    expect(described_class.call(full_name: described_class::ABSENT, social_name: "Mariana").payload).to eq({})
  end

  {
    { full_name: nil } => :invalid_full_name, { full_name: "Ma" } => :invalid_full_name,
    { full_name: "x" * 201 } => :invalid_full_name, { full_name: [ "Maria" ] } => :invalid_full_name,
    { social_name: "x" * 201 } => :invalid_social_name, { social_name: { "a" => 1 } } => :invalid_social_name,
    { mother_name: 42 } => :invalid_mother_name
  }.each do |names, reason|
    it("#{names.inspect.truncate(60)} → #{reason}") { expect(call(**names).reason).to eq(reason) }
  end
end
