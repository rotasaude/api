require "rails_helper"

# Módulo 35a, Task 7 (ADR 0054, Q4; carry-over da revisão da Task 3): o
# terceiro domínio do razão nos dois sentidos — o local vector_control e o
# lote do produto são `vector_control` (nunca `medication`); medicamento e
# vacina não entram no local, e o lote do produto não entra em local de
# farmácia nem de vacina.
RSpec.describe Stock::Domain, type: :model do
  let(:location_class) { Struct.new(:kind) }
  let(:lot_class) do
    Struct.new(:item_kind) do
      def immunobiological? = item_kind == "immunobiological"
      def vector_control? = item_kind == "vector_control"
    end
  end

  def location(kind) = location_class.new(kind)
  def lot(kind) = lot_class.new(kind)

  let(:kinds) { %w[central unit cold_chain_central vaccine_room vector_control] }
  let(:domains) { %w[medication medication immunobiological immunobiological vector_control] }

  it "local e lote resolvem o domínio, inclusive vector_control" do
    expect(kinds.map { |kind| described_class.for(location(kind)) }).to eq(domains)
    expect(%w[medication immunobiological vector_control].map { |kind| described_class.of_lot(lot(kind)) })
      .to eq(%w[medication immunobiological vector_control])
    expect(described_class.feature_for(location("vector_control"))).to eq("vector_control")
    expect(described_class.vector_control?(location("vector_control"))).to be(true)
    expect(described_class.medication?(location("vector_control"))).to be(false)
  end

  it "allows? nos dois sentidos: medicamento e vacina fora do vector_control; o lote do produto fora da farmácia e da vacina" do
    vector = location("vector_control")
    expect(described_class.allows?(vector, lot("vector_control"))).to be(true)
    expect(described_class.allows?(vector, lot("medication"))).to be(false)
    expect(described_class.allows?(vector, lot("immunobiological"))).to be(false)
    %w[central unit cold_chain_central vaccine_room].each do |kind|
      expect(described_class.allows?(location(kind), lot("vector_control"))).to be(false), kind
    end
  end

  it "usable? lê o interruptor do domínio" do
    city = Object.new
    allow(VectorControl::Gate).to receive(:usable?).with(city).and_return(true)
    allow(Pharmacy::Gate).to receive(:usable?).with(city).and_return(false)
    expect(described_class.usable?(city, "vector_control")).to be(true)
    expect(described_class.usable?(city, "medication")).to be(false)
  end
end
