require "rails_helper"

RSpec.describe Neighborhood do
  it "normaliza o nome (pontas e espaços repetidos)" do
    expect(described_class.new(name: "  Santa   Felicidade ", source: "seed").name).to eq("Santa Felicidade")
  end

  it "recusa nome vazio, acima de 120 e origem desconhecida" do
    expect(described_class.new(name: "  ", source: "seed")).not_to be_valid
    expect(described_class.new(name: "x" * 121, source: "seed")).not_to be_valid
    expect(described_class.new(name: "Batel", source: "import")).not_to be_valid
  end

  it "named compara sem diferenciar maiúsculas e sem espaços extras" do
    batel = described_class.create!(name: "Batel", source: "seed")
    expect(described_class.named("  BATEL ")).to eq([ batel ])
  end

  it "active_neighborhoods deixa os inativos de fora" do
    ativo = described_class.create!(name: "Centro", source: "seed")
    described_class.create!(name: "Ahu", source: "seed", active: false)
    expect(described_class.active_neighborhoods).to eq([ ativo ])
  end
end
